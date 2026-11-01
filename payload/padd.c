/* padd: long-running virtual-pad daemon for ps5-mcp.
 *
 * - One instance: the listening port is the lock.
 * - Up to two virtual pads, each fed its state every tick: pad 1 for the foreground user at start, and pad 2 for
 *   the second signed-in user while COMMAND SECOND_PAD has it connected. STATE drives the active pad (COMMAND
 *   SELECT_PAD); the other one stays neutral. HELLO, PING, GET_USER and GET_STATE describe the active pad.
 * - One client at a time; each STATE carries the whole pad state and is ACKed by seq.
 * - Safety: no STATE for watchdog_ms, or a disconnect, forces neutral. A client
 *   silent for idle_ms is dropped. The pads are removed on SHUTDOWN, SIGTERM/SIGINT
 *   and normal exit.
 * - Logs JSON lines to <log_dir>/padd-XXXXXX.
 */
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "protocol.h"
#include "smp.h"
#include "system.h"

/* Bump with every behaviour change: HELLO reports it, and the app compares it with the build to offer an update.
   1.3: uninstall command. 1.4: time spent running a command no longer counts towards the idle drop, and a client
   that hung up no longer makes the next one busy. 1.5: the pad can belong to another signed-in user (PAD_USER), and
   launch always uses the foreground user. 1.7: a second pad for the second signed-in user instead of PAD_USER
   (SECOND_PAD, SELECT_PAD, GET_PADS), and GET_USERS lists the foreground and signed-in users. 1.8: SECOND_PAD
   "connect <user id>". */
#define PADD_VERSION 0x0108

struct config {
    int port;
    const char *log_dir;
    unsigned tick_ms;
    unsigned watchdog_ms;
    unsigned idle_ms;
    int smp_port;               /* ShadowMountPlus API, for uninstalling its titles */
    const char *app_dir;        /* where installed titles live; SMP marks its own with mount.lnk */
};

struct daemon {
    struct config cfg;
    int listen_fd, client_fd;
    uint8_t rx[PMCP_HEADER_BYTES + PMCP_MAX_PAYLOAD];
    size_t rx_len;
    struct pad {
        int32_t user_id, handle;
        int ready;
        struct pmcp_state state;
    } pads[PMCP_PADS];
    int active;                 /* index into pads: the one STATE drives */
    int add_status;             /* pad 1's add at start */
    uint64_t started_ms, last_state_ms, last_rx_ms, last_report_ms;
    uint64_t reports_sent;
    uint32_t report_failures, neutral_events;
    int last_report_status;
    int running;
};

static volatile sig_atomic_t stop_requested;

static void on_signal(int sig) {
    (void)sig;
    stop_requested = 1;
}

static uint64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

static void log_event(const char *event, const char *fmt, ...) {
    printf("{\"event\":\"%s\"", event);
    if (fmt && *fmt) {
        va_list args;
        va_start(args, fmt);
        putchar(',');
        vprintf(fmt, args);
        va_end(args);
    }
    puts("}");
    fflush(stdout);
    fsync(STDOUT_FILENO);
}

static void neutral(struct pmcp_state *state) {
    memset(state, 0, sizeof *state);
    state->lx = state->ly = state->rx = state->ry = 0x80;
}

static int is_neutral(const struct pmcp_state *state) {
    struct pmcp_state n, copy = *state;
    neutral(&n);
    copy.seq = 0;
    return memcmp(&copy, &n, sizeof n) == 0;
}

static int send_message(struct daemon *d, uint8_t type, const void *payload, uint16_t length) {
    uint8_t buffer[PMCP_HEADER_BYTES + PMCP_MAX_PAYLOAD];
    if (d->client_fd < 0 || length > PMCP_MAX_PAYLOAD) return -1;
    memcpy(buffer, PMCP_MAGIC, 4);
    buffer[4] = PMCP_VERSION;
    buffer[5] = type;
    buffer[6] = (uint8_t)(length & 0xff);
    buffer[7] = (uint8_t)(length >> 8);
    if (length) memcpy(buffer + PMCP_HEADER_BYTES, payload, length);
    size_t total = PMCP_HEADER_BYTES + length, sent = 0;
    while (sent < total) {
        ssize_t n = send(d->client_fd, buffer + sent, total - sent, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        sent += (size_t)n;
    }
    return 0;
}

static void send_error_fd(int fd, uint32_t code, const char *message) {
    uint8_t buffer[PMCP_HEADER_BYTES + 4 + 64];
    size_t length = 4 + strnlen(message, 64);
    memcpy(buffer, PMCP_MAGIC, 4);
    buffer[4] = PMCP_VERSION;
    buffer[5] = PMCP_ERROR;
    buffer[6] = (uint8_t)length;
    buffer[7] = 0;
    memcpy(buffer + 8, &code, 4);
    memcpy(buffer + 12, message, length - 4);
    (void)!send(fd, buffer, PMCP_HEADER_BYTES + length, 0);
}

static void send_error(struct daemon *d, uint32_t code, const char *message) {
    if (d->client_fd >= 0) send_error_fd(d->client_fd, code, message);
}

static struct pad *active_pad(struct daemon *d) { return &d->pads[d->active]; }

static int report(struct daemon *d, struct pad *pad) {
    if (!pad->ready) return PMCP_ERR_NO_PAD;
    int status = pad_report(pad->handle, &pad->state);
    d->reports_sent++;
    d->last_report_ms = now_ms();
    if (status) {
        d->report_failures++;
        if (status != d->last_report_status) log_event("report_failed", "\"status\":%d", status);
    }
    d->last_report_status = status;
    return status;
}

static int apply(struct daemon *d) { return report(d, active_pad(d)); }

/* Every pad: only the active one can hold input, but a switch may leave the old one to clear. */
static void force_neutral(struct daemon *d, const char *reason) {
    for (int i = 0; i < PMCP_PADS; i++) {
        struct pad *pad = &d->pads[i];
        if (is_neutral(&pad->state)) continue;
        neutral(&pad->state);
        d->neutral_events++;
        log_event("neutral", "\"reason\":\"%s\",\"pad\":%d", reason, i + 1);
        report(d, pad);
    }
}

static void drop_client(struct daemon *d, const char *reason) {
    if (d->client_fd < 0) return;
    close(d->client_fd);
    d->client_fd = -1;
    d->rx_len = 0;
    log_event("client_closed", "\"reason\":\"%s\"", reason);
    force_neutral(d, "disconnect");
}

/* Title ids are 4 letters and 5 digits (PPSA01234, CUSA01234); anything else never reaches AppInstUtil. */
static int valid_title_id(const char *id) {
    if (strlen(id) != 9) return 0;
    for (int i = 0; i < 9; i++) {
        char c = id[i];
        if (i < 4 ? !(c >= 'A' && c <= 'Z') : !(c >= '0' && c <= '9')) return 0;
    }
    return 1;
}

static uint32_t flags(const struct daemon *d) {
    return (d->pads[d->active].ready ? PMCP_FLAG_PAD_READY : 0) | PMCP_FLAG_TOUCH_UNMAPPED | PMCP_FLAG_USER_NAME
        | PMCP_FLAG_UNINSTALL | PMCP_FLAG_USERS | PMCP_FLAG_PADS;
}

/* The first signed-in user that is not the foreground one, as prospero-win gives a game's controller 1.
   ENOENT: nobody else is signed in. */
static int second_user(int32_t *user_id) {
    int32_t foreground, ids[SYSTEM_LOGIN_USERS];
    int rc = system_foreground_user(&foreground);
    if (rc) return rc;
    if ((rc = system_login_users(ids))) return rc;
    for (int i = 0; i < SYSTEM_LOGIN_USERS; i++) {
        if (ids[i] >= 0 && ids[i] != foreground) {
            *user_id = ids[i];
            return 0;
        }
    }
    return ENOENT;
}

/* "connect" adds pad 2 for the second user, "connect <user id>" for that user (already connected: nothing changes);
   "disconnect" removes it, and pad 1 becomes the active one. A user who is not signed in gets the console's sign-in
   picker with that user selected (docs/findings.md). Pad 2 logs its own events: the runner reads pad_added and pad_removed as padd's start and
   exit. */
static int second_pad(struct daemon *d, const char *arg) {
    struct pad *pad = &d->pads[1];
    if (!strncmp(arg, "connect", 7) && (!arg[7] || arg[7] == ' ')) {
        if (pad->ready) return 0;
        int32_t user_id = -1, handle = -1;
        int status;
        if (arg[7]) {
            char *end;
            long value = strtol(arg + 8, &end, 10);
            if (!arg[8] || *end || value <= 0 || value > INT32_MAX) return EINVAL;
            user_id = (int32_t)value;
            status = 0;
        } else {
            status = second_user(&user_id);
        }
        if (!status) status = pad_add(user_id, &handle);
        if (!status && handle < 0) status = EIO;
        log_event("second_pad_added", "\"ok\":%s,\"status\":%d,\"user_id\":%d,\"handle\":%d",
                  status ? "false" : "true", status, user_id, handle);
        if (status) return status;
        pad->user_id = user_id;
        pad->handle = handle;
        pad->ready = 1;
        neutral(&pad->state);
        report(d, pad);
        return 0;
    }
    if (strcmp(arg, "disconnect")) return EINVAL;
    if (!pad->ready) return 0;
    if (!is_neutral(&pad->state)) {  /* only pad 2: a hold on pad 1 stays */
        neutral(&pad->state);
        d->neutral_events++;
        log_event("neutral", "\"reason\":\"second_pad\",\"pad\":2");
        report(d, pad);
    }
    d->active = 0;
    int status = pad_remove(pad->handle);
    log_event("second_pad_removed", "\"status\":%d,\"handle\":%d", status, pad->handle);
    pad->ready = 0;
    pad->handle = -1;
    pad->user_id = -1;
    return 0;
}

/* "1" or "2": the pad STATE drives from now on. The other one goes neutral. ENOENT: that pad is not connected. */
static int select_pad(struct daemon *d, const char *arg) {
    int index = !strcmp(arg, "1") ? 0 : !strcmp(arg, "2") ? 1 : -1;
    if (index < 0) return EINVAL;
    if (!d->pads[index].ready) return ENOENT;
    if (index != d->active) force_neutral(d, "select_pad");
    d->active = index;
    return 0;
}

static void handle_message(struct daemon *d, uint8_t type, const uint8_t *payload, uint16_t length) {
    switch (type) {
    case PMCP_STATE: {
        if (length != sizeof(struct pmcp_state)) {
            send_error(d, PMCP_ERR_BAD_LENGTH, "STATE must be 28 bytes");
            return;
        }
        struct pad *pad = active_pad(d);
        memcpy(&pad->state, payload, sizeof pad->state);
        d->last_state_ms = now_ms();
        struct pmcp_ack ack = {pad->state.seq, apply(d)};
        send_message(d, PMCP_ACK, &ack, sizeof ack);
        return;
    }
    case PMCP_PING: {
        struct pmcp_pong pong = {0};
        if (length >= 4) memcpy(&pong.token, payload, 4);
        pong.protocol = PMCP_VERSION;
        pong.payload_version = PADD_VERSION;
        pong.uptime_ms = now_ms() - d->started_ms;
        pong.pad_handle = active_pad(d)->handle;
        pong.flags = flags(d);
        pong.reports_sent = d->reports_sent;
        pong.report_failures = d->report_failures;
        pong.neutral_events = d->neutral_events;
        send_message(d, PMCP_PING, &pong, sizeof pong);
        return;
    }
    case PMCP_GET_USER: {
        if (length != 0) {
            send_error(d, PMCP_ERR_BAD_LENGTH, "GET_USER must be empty");
            return;
        }
        struct pmcp_user user = {.user_id = active_pad(d)->user_id};
        user.status = system_user_name(user.user_id, user.name, sizeof user.name);
        if (user.status) memset(user.name, 0, sizeof user.name);
        send_message(d, PMCP_GET_USER, &user, sizeof user);
        return;
    }
    case PMCP_GET_USERS: {
        if (length != 0) {
            send_error(d, PMCP_ERR_BAD_LENGTH, "GET_USERS must be empty");
            return;
        }
        struct pmcp_users users;
        memset(&users, 0, sizeof users);
        if (system_foreground_user(&users.foreground)) users.foreground = -1;
        int32_t ids[SYSTEM_LOGIN_USERS];
        users.status = system_login_users(ids);
        for (int i = 0; i < PMCP_LOGIN_USERS; i++) {
            users.users[i].user_id = !users.status && i < SYSTEM_LOGIN_USERS ? ids[i] : -1;
            if (users.users[i].user_id >= 0
                && system_user_name(users.users[i].user_id, users.users[i].name, sizeof users.users[i].name))
                memset(users.users[i].name, 0, sizeof users.users[i].name);
        }
        send_message(d, PMCP_GET_USERS, &users, sizeof users);
        return;
    }
    case PMCP_GET_PADS: {
        if (length != 0) {
            send_error(d, PMCP_ERR_BAD_LENGTH, "GET_PADS must be empty");
            return;
        }
        struct pmcp_pads pads;
        memset(&pads, 0, sizeof pads);
        pads.active = (uint8_t)(d->active + 1);
        for (int i = 0; i < PMCP_PADS; i++) {
            pads.pads[i].handle = d->pads[i].ready ? d->pads[i].handle : -1;
            pads.pads[i].user_id = d->pads[i].user_id;
        }
        send_message(d, PMCP_GET_PADS, &pads, sizeof pads);
        return;
    }
    case PMCP_GET_STATE:
        send_message(d, PMCP_STATE, &active_pad(d)->state, sizeof active_pad(d)->state);
        return;
    case PMCP_SHUTDOWN: {
        struct pmcp_ack ack = {0, 0};
        log_event("shutdown_requested", "");
        send_message(d, PMCP_ACK, &ack, sizeof ack);
        d->running = 0;
        return;
    }
    case PMCP_COMMAND: {
        if (length != sizeof(struct pmcp_command)) {
            send_error(d, PMCP_ERR_BAD_LENGTH, "COMMAND must be 40 bytes");
            return;
        }
        struct pmcp_command command;
        memcpy(&command, payload, sizeof command);
        command.arg[sizeof command.arg - 1] = '\0';
        int status;
        if (command.op == PMCP_CMD_HOME) {
            log_event("command", "\"op\":\"home\",\"method\":\"%s\"", command.arg);
            status = system_go_home(command.arg);
        } else if (command.op == PMCP_CMD_CLOSE) {
            log_event("command", "\"op\":\"close\"");
            status = system_close_app();
        } else if (command.op == PMCP_CMD_LAUNCH) {
            /* The foreground user launches, even while pad 2 is active: then it is a second player. */
            int32_t user_id;
            if (system_foreground_user(&user_id)) user_id = d->pads[0].user_id;
            log_event("command", "\"op\":\"launch\",\"title_id\":\"%s\",\"user_id\":%d", command.arg, user_id);
            status = system_launch(command.arg, user_id);
        } else if (command.op == PMCP_CMD_SECOND_PAD) {
            log_event("command", "\"op\":\"second_pad\",\"arg\":\"%s\"", command.arg);
            status = second_pad(d, command.arg);
        } else if (command.op == PMCP_CMD_SELECT_PAD) {
            log_event("command", "\"op\":\"select_pad\",\"arg\":\"%s\"", command.arg);
            status = select_pad(d, command.arg);
        } else if (command.op == PMCP_CMD_UNINSTALL) {
            int managed = valid_title_id(command.arg) && smp_managed(d->cfg.app_dir, command.arg);
            log_event("command", "\"op\":\"uninstall\",\"title_id\":\"%s\",\"shadowmount\":%s", command.arg,
                      managed ? "true" : "false");
            status = !valid_title_id(command.arg) ? EINVAL
                   : managed ? smp_uninstall(d->cfg.smp_port, command.arg)
                   : system_uninstall(command.arg);
        } else {
            send_error(d, PMCP_ERR_UNKNOWN_TYPE, "unknown command op");
            return;
        }
        /* A launch or the SMP wait can block this loop for seconds; that is not the client going quiet. */
        d->last_rx_ms = d->last_state_ms = now_ms();
        log_event("command_result", "\"op\":%u,\"status\":%d", command.op, status);
        struct pmcp_ack ack = {command.seq, status};
        send_message(d, PMCP_ACK, &ack, sizeof ack);
        return;
    }
    default:
        send_error(d, PMCP_ERR_UNKNOWN_TYPE, "unknown message type");
    }
}

static void read_client(struct daemon *d) {
    ssize_t n = recv(d->client_fd, d->rx + d->rx_len, sizeof d->rx - d->rx_len, 0);
    if (n < 0 && (errno == EINTR || errno == EAGAIN)) return;
    if (n <= 0) {
        drop_client(d, n == 0 ? "eof" : "recv_error");
        return;
    }
    d->rx_len += (size_t)n;
    d->last_rx_ms = now_ms();
    while (d->running && d->client_fd >= 0 && d->rx_len >= PMCP_HEADER_BYTES) {
        if (memcmp(d->rx, PMCP_MAGIC, 4) != 0) {
            send_error(d, PMCP_ERR_BAD_MAGIC, "bad magic");
            drop_client(d, "bad_magic");
            return;
        }
        if (d->rx[4] != PMCP_VERSION) {
            send_error(d, PMCP_ERR_BAD_VERSION, "unsupported protocol version");
            drop_client(d, "bad_version");
            return;
        }
        uint16_t length = (uint16_t)(d->rx[6] | (d->rx[7] << 8));
        if (length > PMCP_MAX_PAYLOAD) {
            send_error(d, PMCP_ERR_BAD_LENGTH, "payload too long");
            drop_client(d, "bad_length");
            return;
        }
        size_t total = PMCP_HEADER_BYTES + length;
        if (d->rx_len < total) return;
        handle_message(d, d->rx[5], d->rx + PMCP_HEADER_BYTES, length);
        if (d->client_fd < 0) return;
        memmove(d->rx, d->rx + total, d->rx_len - total);
        d->rx_len -= total;
    }
}

static void accept_client(struct daemon *d) {
    int fd = accept(d->listen_fd, NULL, NULL);
    if (fd < 0) return;
    if (d->client_fd >= 0) {
        send_error_fd(fd, PMCP_ERR_BUSY, "another client is connected");
        close(fd);
        log_event("client_rejected", "\"reason\":\"busy\"");
        return;
    }
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
#ifdef SO_NOSIGPIPE
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
    d->client_fd = fd;
    d->rx_len = 0;
    d->last_rx_ms = d->last_state_ms = now_ms();
    log_event("client_connected", "");
    struct pmcp_hello hello = {PMCP_VERSION, PADD_VERSION, active_pad(d)->handle, active_pad(d)->user_id, flags(d),
                               (uint32_t)d->add_status};
    send_message(d, PMCP_HELLO, &hello, sizeof hello);
}

static int open_log(const char *dir) {
    char path[256];
    if (mkdir(dir, 0755) != 0 && errno != EEXIST) return -1;
    snprintf(path, sizeof path, "%s/padd-XXXXXX", dir);
    int fd = mkstemp(path);
    if (fd < 0 || dup2(fd, STDOUT_FILENO) < 0) return -1;
    close(fd);
    return 0;
}

static void parse_args(struct config *cfg, int argc, char **argv) {
    for (int i = 1; i + 1 < argc; i += 2) {
        if (!strcmp(argv[i], "--port")) cfg->port = atoi(argv[i + 1]);
        else if (!strcmp(argv[i], "--log-dir")) cfg->log_dir = argv[i + 1];
        else if (!strcmp(argv[i], "--tick-ms")) cfg->tick_ms = (unsigned)atoi(argv[i + 1]);
        else if (!strcmp(argv[i], "--watchdog-ms")) cfg->watchdog_ms = (unsigned)atoi(argv[i + 1]);
        else if (!strcmp(argv[i], "--idle-ms")) cfg->idle_ms = (unsigned)atoi(argv[i + 1]);
        else if (!strcmp(argv[i], "--smp-port")) cfg->smp_port = atoi(argv[i + 1]);
        else if (!strcmp(argv[i], "--app-dir")) cfg->app_dir = argv[i + 1];
    }
}

int main(int argc, char **argv) {
    static struct daemon d;
    d.cfg = (struct config){PMCP_PORT, "/data/ps5-mcp/logs", 8, 1000, 5000, SMP_PORT, "/user/app"};
    parse_args(&d.cfg, argc, argv);
    d.listen_fd = d.client_fd = -1;
    for (int i = 0; i < PMCP_PADS; i++) {
        d.pads[i].handle = d.pads[i].user_id = -1;
        neutral(&d.pads[i].state);
    }
    d.running = 1;
    d.started_ms = now_ms();

    mkdir("/data/ps5-mcp", 0755);
    if (open_log(d.cfg.log_dir) != 0) {
        perror("open log");
        return 2;
    }
    signal(SIGPIPE, SIG_IGN);
    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    log_event("startup", "\"schema\":1,\"protocol\":%d,\"version\":\"%d.%d\",\"port\":%d,\"tick_ms\":%u,"
              "\"watchdog_ms\":%u,\"idle_ms\":%u", PMCP_VERSION, PADD_VERSION >> 8, PADD_VERSION & 0xff,
              d.cfg.port, d.cfg.tick_ms, d.cfg.watchdog_ms, d.cfg.idle_ms);

    /* The port is the single-instance lock; claim it before touching the pad. */
    d.listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(d.listen_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)d.cfg.port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(d.listen_fd, (struct sockaddr *)&addr, sizeof addr) != 0 || listen(d.listen_fd, 2) != 0) {
        int error = errno;
        log_event("already_running", "\"errno\":%d", error);
        log_event("exit_requested", "\"code\":3");
        return 3;
    }
    log_event("listening", "\"port\":%d", d.cfg.port);

    struct pad *first = &d.pads[0];
    int user_rc = system_foreground_user(&first->user_id);
    log_event("foreground_user", "\"rc\":%d,\"user_id\":%d", user_rc, first->user_id);
    if (user_rc == 0) {
        d.add_status = pad_add(first->user_id, &first->handle);
        first->ready = d.add_status == 0 && first->handle >= 0;
    } else {
        d.add_status = user_rc;
    }
    log_event("pad_added", "\"ok\":%s,\"status\":%d,\"handle\":%d", first->ready ? "true" : "false",
              d.add_status, first->handle);
    if (first->ready) apply(&d);

    uint64_t last_stats = now_ms();
    while (d.running && !stop_requested) {
        struct pollfd fds[2] = {{d.listen_fd, POLLIN, 0}, {d.client_fd, POLLIN, 0}};
        int count = d.client_fd >= 0 ? 2 : 1;
        int ready = poll(fds, (nfds_t)count, (int)d.cfg.tick_ms);
        /* Read the client first: when its close and the next connect arrive together, the next one is not busy. */
        if (ready > 0 && count == 2 && (fds[1].revents & (POLLIN | POLLHUP | POLLERR))) read_client(&d);
        if (ready > 0 && (fds[0].revents & POLLIN)) accept_client(&d);

        uint64_t now = now_ms();
        if (d.client_fd >= 0 && now - d.last_state_ms > d.cfg.watchdog_ms) force_neutral(&d, "watchdog");
        if (d.client_fd >= 0 && now - d.last_rx_ms > d.cfg.idle_ms) drop_client(&d, "idle");
        /* Keep feeding the pads like a real controller does. */
        if (now - d.last_report_ms >= d.cfg.tick_ms) {
            for (int i = 0; i < PMCP_PADS; i++) report(&d, &d.pads[i]);
        }
        if (now - last_stats >= 60000) {
            log_event("stats", "\"reports_sent\":%llu,\"report_failures\":%u,\"neutral_events\":%u",
                      (unsigned long long)d.reports_sent, d.report_failures, d.neutral_events);
            last_stats = now;
        }
    }

    if (stop_requested) log_event("signal", "");
    force_neutral(&d, "exit");
    if (d.client_fd >= 0) close(d.client_fd);
    close(d.listen_fd);
    if (d.pads[1].ready) second_pad(&d, "disconnect");
    int remove_status = first->ready ? pad_remove(first->handle) : 0;
    log_event("pad_removed", "\"status\":%d", remove_status);
    log_event("stats", "\"reports_sent\":%llu,\"report_failures\":%u,\"neutral_events\":%u",
              (unsigned long long)d.reports_sent, d.report_failures, d.neutral_events);
    system_shutdown();
    log_event("exit_requested", "\"code\":%d", remove_status ? 1 : 0);
    return remove_status ? 1 : 0;
}
