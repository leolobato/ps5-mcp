/* SPDX-License-Identifier: GPL-3.0-only */
#include "admission_platform.h"
#include "firmware.h"
#include <ps5/kernel.h>
#include <ps5/mdbg.h>
#include <sys/sysctl.h>
#include <sys/user.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int write_jump_page(pid_t pid, uintptr_t addr, const void *buf, size_t len) {
    uintptr_t page = addr & ~0xFFFUL;
    if (kernel_set_vmem_protection(pid, (intptr_t)page, 0x1000, 7) != 0) return -1;
    int rc = kernel_proc_copyin(pid, buf, (intptr_t)addr, len);
    int restored = kernel_set_vmem_protection(pid, (intptr_t)page, 0x1000, 4);
    return rc == 0 && restored == 0 ? 0 : -1;
}
static pid_t find_remoteplay(const char *comm) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PROC, 0};
    size_t n = 0;
    if (sysctl(mib, 4, NULL, &n, NULL, 0)) return -1;
    char *buf = malloc(n);
    if (!buf || sysctl(mib, 4, buf, &n, NULL, 0)) { free(buf); return -1; }
    pid_t found = -1;
    for (char *p = buf; p < buf + n;) {
        struct kinfo_proc *k = (void *)p;
        p += k->ki_structsize;
        if (!strcmp(k->ki_comm, comm)) found = k->ki_pid;
    }
    free(buf);
    return found;
}
static int find_main_text(pid_t pid, uint64_t *base, uint64_t *size) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_VMMAP, pid};
    size_t n = 0;
    if (sysctl(mib, 4, NULL, &n, NULL, 0)) return -1;
    n = n * 4 / 3;
    char *buf = malloc(n);
    if (!buf || sysctl(mib, 4, buf, &n, NULL, 0)) { free(buf); return -1; }
    *base = 0; *size = 0;
    for (char *p = buf; p < buf + n;) {
        struct kinfo_vmentry *e = (void *)p;
        if (!e->kve_structsize) break;
        p += e->kve_structsize;
        if (e->kve_protection == 4 && e->kve_type == 9 && e->kve_end - e->kve_start > *size) {
            *base = e->kve_start;
            *size = e->kve_end - e->kve_start;
        }
    }
    free(buf);
    return *base ? 0 : -1;
}
static int read_mem(pid_t pid, uintptr_t addr, void *buf, size_t len) {
    return mdbg_copyout(pid, (intptr_t)addr, buf, len);
}
int rp_admission_run(enum rp_admission_mode mode, struct rp_admission_result *result) {
    if (!rp_supported_firmware(kernel_get_fw_version())) {
        memset(result, 0, sizeof *result);
        snprintf(result->code, sizeof result->code, "unsupported-firmware");
        return -1;
    }
    struct rp_admission_ops ops = {
        .find_process = find_remoteplay,
        .region_find = find_main_text,
        .read_mem = read_mem,
        .write_mem = write_jump_page,
    };
    rp_admission(&ops, mode, result);
    return result->ok ? 0 : -1;
}
