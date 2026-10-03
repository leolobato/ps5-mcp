/* Host stub for padd tests: records pad activity instead of touching hardware.
 *
 * PADD_TRACE=<file> receives one JSON line per state *change* and per call, so
 * tests can assert what the console would have seen.
 * PADD_FAIL_ADD=<errno> makes pad_add fail.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "system.h"

static FILE *trace;
static struct pmcp_state last;
static int have_last;
static int32_t next_handle = 1000;

static void emit(const char *line) {
    if (!trace) {
        const char *path = getenv("PADD_TRACE");
        if (!path || !(trace = fopen(path, "a"))) return;
        setvbuf(trace, NULL, _IOLBF, 0);
    }
    fputs(line, trace);
}

int system_foreground_user(int32_t *user_id) {
    *user_id = 0x11ecf8b9;
    return 0;
}

int system_user_name(int32_t user_id, char *name, size_t size) {
    (void)user_id;
    const char *fail = getenv("PADD_FAIL_USER_NAME");
    const char *value = getenv("PADD_USER_NAME");
    snprintf(name, size, "%s", fail ? "" : value ? value : "Test Player");
    return fail ? atoi(fail) : 0;
}

int pad_add(int32_t user_id, int32_t *handle) {
    const char *fail = getenv("PADD_FAIL_ADD");
    char line[128];
    snprintf(line, sizeof line, "{\"call\":\"pad_add\",\"user_id\":%d}\n", user_id);
    emit(line);
    if (fail) return atoi(fail);
    *handle = next_handle++;
    return 0;
}

int pad_report(int32_t handle, const struct pmcp_state *state) {
    struct pmcp_state copy = *state;
    copy.seq = 0;
    if (have_last && memcmp(&copy, &last, sizeof copy) == 0) return 0;
    last = copy;
    have_last = 1;
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
