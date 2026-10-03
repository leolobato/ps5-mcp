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

/* Each returns 0 on success, an errno (>0) or an SCE error code (<0). */
int pad_add(int32_t user_id, int32_t *handle);
int pad_report(int32_t handle, const struct pmcp_state *state);
int pad_remove(int32_t handle);

/* method: "" or "system", "shellcore", "suspend" (suspend the running big app). */
int system_go_home(const char *method);
/* Close (kill) the running big app; the system returns to the home screen. */
int system_close_app(void);
int system_launch(const char *title_id, int32_t user_id);
/* Ask the system to uninstall a title. Returns once the request is accepted; files go away afterwards. */
int system_uninstall(const char *title_id);

void system_shutdown(void);

#endif
