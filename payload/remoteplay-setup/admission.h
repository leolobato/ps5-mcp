/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef RP_ADMISSION_H
#define RP_ADMISSION_H
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#define RP_ADM_HEX_MAX 80

enum rp_admission_mode { RP_ADMISSION_CHECK, RP_ADMISSION_APPLY, RP_ADMISSION_RESTORE };

/* Injected kernel/process operations so the decision logic is host-testable. */
struct rp_admission_ops {
    pid_t (*find_process)(const char *comm);
    int (*region_find)(pid_t pid, uint64_t *base, uint64_t *size);
    int (*read_mem)(pid_t pid, uintptr_t addr, void *buf, size_t len);
    int (*write_mem)(pid_t pid, uintptr_t addr, const void *buf, size_t len);
};

struct rp_admission_result {
    int ok, already, changed, stock, patched, pid;
    int rollback_attempted, rollback_verified;
    uint64_t base;
    char code[32], message[256];
    char before[RP_ADM_HEX_MAX], after[RP_ADM_HEX_MAX];
};

void rp_admission(const struct rp_admission_ops *, enum rp_admission_mode,
                  struct rp_admission_result *);
int rp_admission_json(const struct rp_admission_result *, char *out, size_t cap);
#endif
