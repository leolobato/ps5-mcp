/* SPDX-License-Identifier: GPL-3.0-only
 * One-shot Remote Play admission patch runner. Applies, checks or restores the
 * per-boot SceRemotePlay admission patch described in admission.c and writes a
 * fixed numeric report to /data/remoteplay-setup.admission.json. Build modes:
 *   default                -> apply (idempotent)
 *   -DRP_ADM_MODE_CHECK    -> report only
 *   -DRP_ADM_MODE_RESTORE  -> restore stock bytes
 */
#include "admission_platform.h"
#include "build_info.h"
#include "files.h"
#include <ps5/kernel.h>
#include <ps5/mdbg.h>
#include <sys/sysctl.h>
#include <sys/user.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern int rp_file_write(const char *path, const unsigned char *data, size_t size);
int main(void) {
    enum rp_admission_mode mode =
#ifdef RP_ADM_MODE_CHECK
        RP_ADMISSION_CHECK;
#elif defined(RP_ADM_MODE_RESTORE)
        RP_ADMISSION_RESTORE;
#else
        RP_ADMISSION_APPLY;
#endif
    struct rp_admission_result result;
    rp_admission_run(mode, &result);
    char json[2048];
    if (rp_admission_json(&result, json, sizeof json) != 0) return 1;
    char wrapped[2300];
    int n = snprintf(wrapped, sizeof wrapped,
                     "%.*s,\"mode\":\"%s\",\"buildId\":\"" RP_BUILD_ID "\"}",
                     (int)strlen(json) - 1, json,
                     mode == RP_ADMISSION_APPLY ? "apply" :
                     mode == RP_ADMISSION_RESTORE ? "restore" : "check");
    if (n < 0 || (size_t)n >= sizeof wrapped) return 1;
    if (rp_file_write("/data/remoteplay-setup.admission.json",
                      (const unsigned char *)wrapped, (size_t)n) != 0)
        return 1;
    puts(result.ok ? "Remote Play admission patch report saved."
                   : "Remote Play admission patch failed; report saved.");
    return result.ok ? 0 : 1;
}
