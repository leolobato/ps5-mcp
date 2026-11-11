/* Host stub for padd tests: records pad activity instead of touching hardware.
 *
 * PADD_TRACE=<file> receives one JSON line per state *change* and per call, so
 * tests can assert what the console would have seen.
 * PADD_FAIL_ADD=<errno> makes pad_add fail; PADD_FAIL_ADD_USER=<user id> limits that to one user.
 * PADD_LOGIN_USERS=<id>,<id>... are the signed-in users (default: only the foreground user);
 * PADD_FAIL_LOGIN_USERS=<status> makes that list fail.
 * PADD_USER_NAME and PADD_GUEST_NAME name the foreground user and the others; PADD_NAME_<user id> names one user.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "system.h"

static FILE *trace;
/* The last state traced per pad (padd feeds up to two), so a repeat is skipped but each pad's first report shows. */
static struct {
    int32_t handle;
    struct pmcp_state state;
} last[16];
static int lasts;
static int32_t next_handle = 1000;

static void emit(const char *line) {
    if (!trace) {
        const char *path = getenv("PADD_TRACE");
        if (!path || !(trace = fopen(path, "a"))) return;
        setvbuf(trace, NULL, _IOLBF, 0);
    }
    fputs(line, trace);
}

#define FOREGROUND_USER 0x11ecf8b9

int system_foreground_user(int32_t *user_id) {
    *user_id = FOREGROUND_USER;
    return 0;
}

int system_login_users(int32_t ids[SYSTEM_LOGIN_USERS]) {
    const char *fail = getenv("PADD_FAIL_LOGIN_USERS");
    const char *list = getenv("PADD_LOGIN_USERS");
    for (int i = 0; i < SYSTEM_LOGIN_USERS; i++) ids[i] = -1;
    if (fail) return atoi(fail);
    if (!list) {
        ids[0] = FOREGROUND_USER;
        return 0;
    }
    char *end;
    for (int i = 0; i < SYSTEM_LOGIN_USERS && *list; i++) {
        ids[i] = (int32_t)strtol(list, &end, 0);
        list = *end == ',' ? end + 1 : end;
    }
    return 0;
}

/* The foreground user is PADD_USER_NAME ("Test Player"); the others are PADD_GUEST_NAME or "Guest <id>". */
int system_user_name(int32_t user_id, char *name, size_t size) {
    const char *fail = getenv("PADD_FAIL_USER_NAME");
    const char *value = getenv("PADD_USER_NAME");
    const char *guest = getenv("PADD_GUEST_NAME");
    char key[32];
    snprintf(key, sizeof key, "PADD_NAME_%d", user_id);
    const char *own = getenv(key);
    if (fail) snprintf(name, size, "%s", "");
    else if (own) snprintf(name, size, "%s", own);
    else if (user_id != FOREGROUND_USER && guest) snprintf(name, size, "%s", guest);
    else if (user_id != FOREGROUND_USER) snprintf(name, size, "Guest %d", user_id);
    else snprintf(name, size, "%s", value ? value : "Test Player");
    return fail ? atoi(fail) : 0;
}

int pad_add(int32_t user_id, int32_t *handle) {
    const char *fail = getenv("PADD_FAIL_ADD");
    const char *only = getenv("PADD_FAIL_ADD_USER");
    char line[128];
    snprintf(line, sizeof line, "{\"call\":\"pad_add\",\"user_id\":%d}\n", user_id);
    emit(line);
    if (fail && (!only || strtol(only, NULL, 0) == user_id)) return atoi(fail);
    *handle = next_handle++;
    return 0;
}

int pad_report(int32_t handle, const struct pmcp_state *state) {
    struct pmcp_state copy = *state;
    copy.seq = 0;
    int i = 0;
    while (i < lasts && last[i].handle != handle) i++;
    if (i < lasts && memcmp(&copy, &last[i].state, sizeof copy) == 0) return 0;
    if (i == lasts) {
        if (lasts == 16) i = lasts - 1;  /* many old handles: reuse the newest slot */
        else lasts++;
    }
    last[i].handle = handle;
    last[i].state = copy;
    char line[256];
    snprintf(line, sizeof line,
             "{\"call\":\"pad_report\",\"handle\":%d,\"buttons\":%u,\"lx\":%u,\"ly\":%u,\"rx\":%u,\"ry\":%u,"
             "\"l2\":%u,\"r2\":%u}\n", handle, state->buttons, state->lx, state->ly, state->rx, state->ry,
             state->l2, state->r2);
    emit(line);
    return 0;
}

int pad_remove(int32_t handle) {
    char line[64];
    snprintf(line, sizeof line, "{\"call\":\"pad_remove\",\"handle\":%d}\n", handle);
    emit(line);
    return 0;
}

int system_go_home(const char *method) {
    char line[96];
    snprintf(line, sizeof line, "{\"call\":\"go_home\",\"method\":\"%.16s\"}\n", method);
    emit(line);
    return strcmp(method, "bogus") == 0 ? 22 : 0;
}

int system_close_app(void) {
    emit("{\"call\":\"close_app\"}\n");
    return 0;
}

int system_launch(const char *title_id, int32_t user_id) {
    char line[128];
    snprintf(line, sizeof line, "{\"call\":\"launch\",\"title_id\":\"%.31s\",\"user_id\":%d}\n", title_id, user_id);
    emit(line);
    const char *delay = getenv("PADD_LAUNCH_DELAY_MS");  /* a slow launch, as the console's can be */
    if (delay) usleep((useconds_t)atoi(delay) * 1000);
    return strcmp(title_id, "BADTITLE") == 0 ? (int)0x80940005u : 0;
}

int system_uninstall(const char *title_id) {
    char line[96];
    snprintf(line, sizeof line, "{\"call\":\"uninstall\",\"title_id\":\"%.31s\"}\n", title_id);
    emit(line);
    return strcmp(title_id, "BUSY00001") == 0 ? (int)0x80A30005u : 0;
}

void system_shutdown(void) {
    emit("{\"call\":\"shutdown\"}\n");
    if (trace) fclose(trace);
    trace = NULL;
}
