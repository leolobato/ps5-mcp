/* Uninstalling a title that ShadowMountPlus (SMP) manages.
 *
 * SMP marks its titles with /user/app/<id>/mount.lnk and installs them again from their source on its next scan,
 * so a plain AppInstUtil uninstall does not last. For those titles, SMP's own storage job deletes the source first
 * (it unmounts every title of that source, refuses an image shared by several titles, and holds the scanner while
 * it runs), and the title is uninstalled once the job is done. SMP's API listens on 127.0.0.1:10101 only.
 */
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include "smp.h"
#include "system.h"

#define SMP_WAIT_MS 6000  /* the client waits 10 s for the ACK */

static void pause_ms(unsigned ms) {
    struct timespec t = {(time_t)(ms / 1000), (long)(ms % 1000) * 1000000L};
    nanosleep(&t, NULL);
}

/* POSTs a JSON body to SMP. Returns the HTTP status (0 = no answer) and the body in `out`. */
static int smp_post(int port, const char *path, const char *body, char *out, size_t size) {
    out[0] = '\0';
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return 0;
    struct timeval timeout = {2, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof timeout);
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
        close(fd);
        return 0;
    }
    char request[512];
    int length = snprintf(request, sizeof request,
                          "POST %s HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n"
                          "Content-Length: %zu\r\nConnection: close\r\n\r\n%s", path, strlen(body), body);
    if (length < 0 || (size_t)length >= sizeof request || send(fd, request, (size_t)length, 0) != length) {
        close(fd);
        return 0;
    }
    size_t used = 0;
    ssize_t got;
    while (used + 1 < size && (got = recv(fd, out + used, size - 1 - used, 0)) > 0) used += (size_t)got;
    out[used] = '\0';
    close(fd);
    int status = 0;
    if (sscanf(out, "HTTP/%*s %d", &status) != 1) return 0;
    char *json = strstr(out, "\r\n\r\n");
    if (json) memmove(out, json + 4, strlen(json + 4) + 1);
    return status;
}

/* The text after `"key":` in SMP's json-c output (spaced or not), or NULL. */
static const char *json_value(const char *json, const char *key) {
    char quoted[64];
    snprintf(quoted, sizeof quoted, "\"%s\"", key);
    const char *at = strstr(json, quoted);
    if (!at) return NULL;
    at += strlen(quoted);
    while (*at == ' ' || *at == ':') at++;
    return at;
}

static int json_true(const char *json, const char *key) {
    const char *at = json_value(json, key);
    return at && strncmp(at, "true", 4) == 0;
}

static long json_long(const char *json, const char *key, long missing) {
    const char *at = json_value(json, key);
    return at && (*at == '-' || (*at >= '0' && *at <= '9')) ? strtol(at, NULL, 10) : missing;
}

int smp_managed(const char *app_dir, const char *title_id) {
    char path[256];
    struct stat st;
    snprintf(path, sizeof path, "%s/%s/mount.lnk", app_dir, title_id);
    return stat(path, &st) == 0;
}

int smp_uninstall(int port, const char *title_id) {
    char body[96], reply[4096];
    snprintf(body, sizeof body, "{\"title_id\":\"%s\",\"confirm\":true}", title_id);
    int http = smp_post(port, "/api/v1/games/delete", body, reply, sizeof reply);
    if (http == 0) return ECONNREFUSED;  /* SMP is not running: an uninstall would come back with it */
    if (http == 409) return EBUSY;       /* another storage job, or a game is running */
    if (http == 404 && strstr(reply, "unknown API route")) return ENOTSUP;  /* an SMP without source delete */
    if (http == 202) {
        /* SMP keeps one job. Uninstall only when ours completed: after a failed delete the source is still
         * there, and SMP's recovery scan installs the title again at once. */
        long job = json_long(reply, "job_id", -1);
        int waited = 0;
        for (;;) {
            pause_ms(200);
            waited += 200;
            int code = smp_post(port, "/api/v1/games/storage/status", "{}", reply, sizeof reply);
            if (code == 200 && !json_true(reply, "active")) break;
            if (waited >= SMP_WAIT_MS) return EINPROGRESS;  /* a large source; ask again when it is gone */
        }
        if (json_long(reply, "job_id", -2) != job) return EBUSY;  /* replaced by another job; ask again */
        long result = json_long(reply, "result_status", EIO);
        if (result != 0) return (int)result;                     /* e.g. EACCES: a file SMP may not delete */
        if (!strstr(reply, "\"completed\"")) return EIO;     /* cancelled */
    } else if (http != 404) {             /* 404: no source left, nothing would bring the title back */
        return EIO;
    }
    return system_uninstall(title_id);
}
