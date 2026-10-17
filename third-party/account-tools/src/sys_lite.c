/* PS5 Account Tools — minimal system support.
 *
 * Standalone (no elf-arsenal deps). Provides only what the in-process feature
 * modules (npsignin, offact, avatar) and the lean web server need:
 *   - credential escalation + UserService init at load (constructor)
 *   - foreground-user lookup
 *
 * Escalation is done directly against the ps5-payload-sdk kernel API
 * (<ps5/kernel.h>, linked via -lkernel_sys) rather than a vendored helper.
 * It is required so the payload can touch the system registry (sceRegMgr*)
 * and write the per-user NP files under /system_data/priv.
 */

#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <sys/syscall.h>

#include <ps5/kernel.h>

#include "sys.h"


/* ------------------------------------------------------------------ *
 * SceUserService                                                       *
 * ------------------------------------------------------------------ */

int  sceUserServiceInitialize(void*);
void sceUserServiceTerminate(void);
int  sceUserServiceGetForegroundUser(uint32_t *user_id);
int  sceUserServiceGetUserName(int32_t user_id, char *name, size_t max_size);


/* ------------------------------------------------------------------ *
 * Credential escalation (native SDK kernel API).                       *
 *                                                                      *
 * Grants root uids/gids, an unrestricted authid + capabilities, and    *
 * breaks out of the jail by pointing rootdir/jaildir at the real root  *
 * vnode. Mirrors the standard ps5-payload escalation.                  *
 * ------------------------------------------------------------------ */

#define JB_AUTHID  0x4801000000000013ULL

static int
escalate_creds(pid_t pid) {
  if(pid <= 0) return -1;
  if(!kernel_get_proc(pid)) return -1;

  int rc = 0;

  /* uid/gid → 0 (root) on every cred slot the kernel checks. */
  if(kernel_set_ucred_uid  (pid, 0) != 0) rc = -1;
  if(kernel_set_ucred_ruid (pid, 0) != 0) rc = -1;
  if(kernel_set_ucred_svuid(pid, 0) != 0) rc = -1;
  if(kernel_set_ucred_rgid (pid, 0) != 0) rc = -1;
  if(kernel_set_ucred_svgid(pid, 0) != 0) rc = -1;

  /* Escape the jail so /system_data/priv is reachable. */
  intptr_t rootvnode = kernel_get_root_vnode();
  if(rootvnode) {
    if(kernel_set_proc_rootdir(pid, rootvnode) != 0) rc = -1;
    if(kernel_set_proc_jaildir(pid, rootvnode) != 0) rc = -1;
  }

  /* Unrestricted authid + full capabilities + high-attr flag. */
  if(kernel_set_ucred_authid(pid, JB_AUTHID) != 0) rc = -1;
  uint8_t caps[16];
  memset(caps, 0xff, sizeof(caps));
  if(kernel_set_ucred_caps(pid, caps) != 0) rc = -1;

  uint8_t attrs[32] = {0};
  attrs[0] = 0x80;
  if(kernel_set_ucred_attrs(pid, attrs) != 0) rc = -1;

  return rc;
}


/* ------------------------------------------------------------------ *
 * Foreground user                                                      *
 * ------------------------------------------------------------------ */

uint32_t
sys_get_foreground_user(char *name_out, size_t name_out_size) {
  uint32_t uid = 0;
  if(sceUserServiceGetForegroundUser(&uid) != 0 || uid == 0) {
    if(name_out && name_out_size > 0) name_out[0] = 0;
    return 0;
  }
  if(name_out && name_out_size > 0) {
    char tmp[17] = {0};
    if(sceUserServiceGetUserName((int32_t)uid, tmp, sizeof(tmp)) != 0) {
      tmp[0] = 0;
    }
    size_t n = strlen(tmp);
    if(n >= name_out_size) n = name_out_size - 1;
    memcpy(name_out, tmp, n);
    name_out[n] = 0;
  }
  return uid;
}


/* ------------------------------------------------------------------ *
 * Startup: escalate our own creds and bring up UserService.            *
 * ------------------------------------------------------------------ */

__attribute__((constructor)) static void
sys_lite_init(void) {
  int err;

  signal(SIGPIPE, SIG_IGN);
  signal(SIGCHLD, SIG_IGN);

  /* Root creds + jailbreak so we can touch the registry / profile cache /
     per-user NP files. */
  escalate_creds(getpid());
  syscall(SYS_thr_set_name, -1, "ps5-acct-tools");

  if((err = sceUserServiceInitialize(0)) &&
     err != 0x80960003 /* SCE_USER_SERVICE_ERROR_NOT_TERMINATED */) {
    perror("sceUserServiceInitialize");
    /* fall through — the web UI still works without a signed-in user. */
  }
}

__attribute__((destructor)) static void
sys_lite_fini(void) {
  sceUserServiceTerminate();
}
