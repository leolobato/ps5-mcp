/* SPDX-License-Identifier: GPL-3.0-only
 * One-shot, account-read-only diagnostics. No listener or account mutation path. */
#include "setup.h"
#include "build_info.h"
#include "files.h"
#include <stdio.h>
#include <stdlib.h>
extern const struct rp_ops rp_platform;
extern int rp_platform_init(char firmware[16]);
extern uint32_t rp_platform_firmware_raw(void);
extern int rp_platform_registry_probe(uint32_t,unsigned,unsigned);
int main(void) {
    char firmware[16];
    if(rp_platform_init(firmware)) return 1;
    char *report=malloc(16384); if(!report) return 1;
#ifdef RP_VERIFY_RESTORATION
    int n=rp_restore_diagnostics(&rp_platform,report,16384);
    const char *report_path="/data/remoteplay-setup.restoration.json";
#else
    int n=rp_registry_diagnostics(&rp_platform,rp_platform_registry_probe,report,16384);
    const char *report_path="/data/remoteplay-setup.diagnostics.json";
#endif
    if(n<1 || n>=16384 || report[n-1]!='}') { free(report); return 1; }
    int added=snprintf(report+n-1,16384-(size_t)n+1,
        ",\"firmware\":\"%s\",\"firmwareRaw\":\"0x%08x\",\"legacyProfileEnabled\":%s,\"buildId\":\"" RP_BUILD_ID "\"}",
        firmware,rp_platform_firmware_raw(),
        rp_platform.legacy_profile_enabled && rp_platform.legacy_profile_enabled() ? "true" : "false");
    if(added<0 || (size_t)added>=16384-(size_t)n+1) { free(report); return 1; }
    n=n-1+added;
    /* Only this fixed report file is written; it contains key/schema/status
     * metadata, never account names, account IDs, registry values or NP data. */
    int status=rp_file_write(report_path,(unsigned char *)report,(size_t)n);
    free(report);
    if(status) return 1;
    puts("Remote Play read-only registry diagnostic report saved.");
    return 0;
}
