/* What padd needs from the console. Two implementations:
 *   system_ps5.c  - the real /dev/hid pad and system services (docs/vpad-abi.md)
 *   system_host.c - a recording stub, so the daemon logic can be tested on the Mac
 */
#ifndef PS5MCP_SYSTEM_H
#define PS5MCP_SYSTEM_H

#include <stddef.h>
#include <stdint.h>

#include "protocol.h"

/* Returns 0 and the foreground user id, or an SCE error code. */
int system_foreground_user(int32_t *user_id);
int system_user_name(int32_t user_id, char *name, size_t size);

/* Room in sceUserServiceGetLoginUserIdList's list; an empty slot is -1. */
#define SYSTEM_LOGIN_USERS 4
/* Returns 0 and the signed-in users' ids, ENOSYS when the call is missing, or an SCE error code. */
int system_login_users(int32_t ids[SYSTEM_LOGIN_USERS]);

/* Each returns 0 on success, an errno (>0) or an SCE error code (<0). */
int pad_add(int32_t user_id, int32_t *handle);
int pad_report(int32_t handle, const struct pmcp_state *state);
int pad_remove(int32_t handle);

/* method: "" or "system", "shellcore", "suspend" (suspend the running big app). */
int system_go_home(const char *method);
/* Close (kill) the running big app; the system returns to the home screen. */
int system_close_app(void);
/* Returns 0 (and the new app's id in *app_id, or -1 when the console gave none) or an SCE error code. */
int system_launch(const char *title_id, int32_t user_id, int32_t *app_id);
/* Bring a running app to the front: a launch from the home screen leaves it behind (docs/ps-button.md). */
int system_focus_app(int32_t app_id);
/* Ask the system to uninstall a title. Returns once the request is accepted; files go away afterwards. */
int system_uninstall(const char *title_id);

/* Name the calling thread, best effort. elfldr calls everything it starts "payload.elf", and process lists show the
 * name of one of the process's threads. padd has only the main thread, so its name is the one they show. */
void system_set_name(const char *name);

void system_shutdown(void);

#endif
