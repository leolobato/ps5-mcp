/* Console side of padd: the /dev/hid virtual pad plus system services. */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include "system.h"

int sceUserServiceInitialize(void *params);
int sceUserServiceGetForegroundUser(int32_t *user_id);
int sceUserServiceTerminate(void);
__attribute__((weak)) int sceUserServiceGetUserName(int32_t user_id, char *name, size_t size);
/* Not yet proven on 13.60: weak, so an unresolved import becomes ENOSYS instead of a failed load. */
__attribute__((weak)) int sceSystemServiceNavigateToGoHome(void);
__attribute__((weak)) int sceLncUtilInitialize(void);
__attribute__((weak)) uint32_t sceLncUtilLaunchApp(const char *title_id, const char **argv, void *param);
__attribute__((weak)) int sceShellCoreUtilNavigateToGoHome(void);
__attribute__((weak)) int sceLncUtilGetAppIdOfRunningBigApp(void);
__attribute__((weak)) int sceLncUtilSuspendApp(int app_id, int flag);
__attribute__((weak)) int sceLncUtilKillApp(int app_id);
/* As ps5-payload-dev/ftpsrv declares them. */
__attribute__((weak)) int sceAppInstUtilInitialize(void);
__attribute__((weak)) int sceAppInstUtilAppUnInstall(const char *title_id);

#define IOCTL_PAD_ADD    0xC018482AUL
#define IOCTL_PAD_REPORT 0x8018482CUL
#define IOCTL_PAD_REMOVE 0x80104850UL
#define OP_ADD    3
#define OP_REMOVE 5

#define DESCRIPTOR_BYTES  168
#define DESC_PROTOCOL_AT  0x00
#define DESC_USER_AT      0x1C
#define DESC_CLASS_AT     0x20

#define REPORT_BYTES      0xA0
#define REPORT_BUTTONS_AT 0x0C
#define REPORT_STICKS_AT  0x10
#define REPORT_L2_AT      0x14
#define REPORT_R2_AT      0x15
#define REPORT_ACTIVE_AT  0x17
#define REPORT_MOTION_AT  0x78

/* Launch parameters as used by public PS5 homebrew (32 bytes, natural alignment). */
struct launch_param {
    uint32_t size;
    uint32_t user_id;
    uint32_t app_opt;
    uint64_t crash_report;
    uint32_t check_flag;
};
#define LAUNCH_SKIP_SYSTEM_UPDATE_CHECK 2

struct pad_request { uint32_t op_or_handle; uint32_t unused; void *in; void *out; };
struct pad_remove_request { uint8_t op; uint8_t unused[7]; uint32_t handle; uint32_t unused2; };

static int hid_fd = -1;
static int user_service_ready;
static int launcher_ready;
static int installer_ready;

int system_foreground_user(int32_t *user_id) {
    if (!user_service_ready) {
        int rc = sceUserServiceInitialize(NULL);
        if (rc) return rc;
        user_service_ready = 1;
    }
    return sceUserServiceGetForegroundUser(user_id);
}

int system_user_name(int32_t user_id, char *name, size_t size) {
    if (!size) return EINVAL;
    memset(name, 0, size);
    if (!user_service_ready || !sceUserServiceGetUserName) return ENOSYS;
    int rc = sceUserServiceGetUserName(user_id, name, size);
    name[size - 1] = '\0';
    if (rc) memset(name, 0, size);
    return rc;
}

int pad_add(int32_t user_id, int32_t *handle) {
    if (hid_fd < 0 && (hid_fd = open("/dev/hid", O_RDWR)) < 0) return errno;
    uint8_t descriptor[DESCRIPTOR_BYTES] = {0};
    descriptor[DESC_PROTOCOL_AT] = 3;
    memcpy(descriptor + DESC_USER_AT, &user_id, sizeof user_id);
    descriptor[DESC_CLASS_AT] = 1;
    struct pad_request request = {OP_ADD, 0, descriptor, handle};
    *handle = -1;
    return ioctl(hid_fd, IOCTL_PAD_ADD, &request) ? errno : 0;
}

int pad_report(int32_t handle, const struct pmcp_state *state) {
    uint8_t report[REPORT_BYTES] = {0};
    const float quaternion_w = 1.0f;
    memcpy(report + REPORT_BUTTONS_AT, &state->buttons, sizeof state->buttons);
    report[REPORT_STICKS_AT + 0] = state->lx;
    report[REPORT_STICKS_AT + 1] = state->ly;
    report[REPORT_STICKS_AT + 2] = state->rx;
    report[REPORT_STICKS_AT + 3] = state->ry;
    report[REPORT_L2_AT] = state->l2;
    report[REPORT_R2_AT] = state->r2;
    report[REPORT_ACTIVE_AT] = 1;
    memcpy(report + REPORT_MOTION_AT + 12, &quaternion_w, sizeof quaternion_w);
    /* Touch points have no known place in this report yet (PMCP_FLAG_TOUCH_UNMAPPED). */
    struct pad_request request = {(uint32_t)handle, 0, report, NULL};
    return ioctl(hid_fd, IOCTL_PAD_REPORT, &request) ? errno : 0;
}

int pad_remove(int32_t handle) {
    struct pad_remove_request request = {.op = OP_REMOVE, .handle = (uint32_t)handle};
    return ioctl(hid_fd, IOCTL_PAD_REMOVE, &request) ? errno : 0;
}

/* LncUtil calls fail with 0x80940004 until the client is initialised. */
static int launcher_init(void) {
    if (launcher_ready) return 0;
    if (!sceLncUtilInitialize) return ENOSYS;
    int rc = sceLncUtilInitialize();
    if (rc && (uint32_t)rc != 0x80940018u) return rc;  /* already initialised is fine */
    launcher_ready = 1;
    return 0;
}

static int running_big_app(void) {
    if (!sceLncUtilGetAppIdOfRunningBigApp) return -ENOSYS;
    return sceLncUtilGetAppIdOfRunningBigApp();
}

int system_go_home(const char *method) {
    int rc = launcher_init();
    if (rc) return rc;
    if (!method[0] || !strcmp(method, "system")) {
        if (!sceSystemServiceNavigateToGoHome) return ENOSYS;
        return sceSystemServiceNavigateToGoHome();
    }
    if (!strcmp(method, "shellcore")) {
        if (!sceShellCoreUtilNavigateToGoHome) return ENOSYS;
        return sceShellCoreUtilNavigateToGoHome();
    }
    if (!strcmp(method, "suspend")) {
        int app = running_big_app();
        if (app < 0 && (uint32_t)app & 0x80000000u) return app;
        if (!sceLncUtilSuspendApp) return ENOSYS;
        return sceLncUtilSuspendApp(app, 0);
    }
    return EINVAL;
}

int system_close_app(void) {
    int rc = launcher_init();
    if (rc) return rc;
    int app = running_big_app();
    if ((uint32_t)app & 0x80000000u) return app;
    if (!sceLncUtilKillApp) return ENOSYS;
    return sceLncUtilKillApp(app);
}

int system_launch(const char *title_id, int32_t user_id) {
    if (!sceLncUtilLaunchApp) return ENOSYS;
    int rc = launcher_init();
    if (rc) return rc;
    /* Flag order as public PS5 homebrew uses it: none first, others only on invalid-param. */
    const uint32_t flags[] = {0, LAUNCH_SKIP_SYSTEM_UPDATE_CHECK, 1};
    uint32_t result = 0;
    for (unsigned i = 0; i < sizeof flags / sizeof flags[0]; i++) {
        struct launch_param param = {sizeof param, (uint32_t)user_id, 0, 0, flags[i]};
        result = sceLncUtilLaunchApp(title_id, NULL, &param);
        if (result != 0x80940005u) break;
    }
    /* Success returns the new app id; SCE errors have bit 31 set. */
    return (result & 0x80000000u) ? (int)result : 0;
}

int system_uninstall(const char *title_id) {
    if (!sceAppInstUtilInitialize || !sceAppInstUtilAppUnInstall) return ENOSYS;
    if (!installer_ready) {
        int rc = sceAppInstUtilInitialize();
        if (rc) return rc;
        installer_ready = 1;  /* stays initialised: AppInstUtil calls fail once it is terminated */
    }
    return sceAppInstUtilAppUnInstall(title_id);
}

void system_shutdown(void) {
    if (hid_fd >= 0) close(hid_fd);
    hid_fd = -1;
    if (user_service_ready) sceUserServiceTerminate();
    user_service_ready = 0;
}
