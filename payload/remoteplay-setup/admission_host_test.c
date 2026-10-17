/* SPDX-License-Identifier: GPL-3.0-only
 * Host-only tests for the admission patch decision logic. No console, kernel
 * or process access: memory is a simulated 32-byte context window. */
#include "admission.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned char memory[4096];
static pid_t simulated_pid = 61;
static int find_calls, region_calls, read_calls, write_calls;
static int fail_find, fail_region, fail_read, fail_write, fail_verify_read;
static int fail_second_write, fail_after_write, corrupt_verify;
static uint64_t region_base = 0x58cc8000, region_size = 0x46c000;

static const unsigned char stock[32] = {
    0xb9,0x52,0x10,0xfc,0x80,0x85,0xc0,0x78,0x18,0x80,0x7d,0xaf,0x00,0x74,0x12,
    0x8b,0x45,0x94,0x89,0x83,0x70,0x04,0x00,0x00,0x83,0x4d,0x88,0x02,0x41,0xb7,0x01,0xeb
};

static pid_t find_process(const char *comm) {
    (void)comm; find_calls++;
    return fail_find ? -1 : simulated_pid;
}
static int region_find(pid_t pid, uint64_t *base, uint64_t *size) {
    (void)pid; region_calls++;
    if (fail_region) return -1;
    *base = region_base; *size = region_size;
    return fail_region ? -1 : 0;
}
static int read_mem(pid_t pid, uintptr_t addr, void *buf, size_t len) {
    (void)pid; read_calls++;
    if (fail_read || (fail_verify_read && read_calls > 1)) return -1;
    if (corrupt_verify && read_calls == 2) memory[7] ^= 1;
    uintptr_t off = addr - (uintptr_t)region_base - 0x43B44;
    if (off + len > sizeof memory) return -1;
    memcpy(buf, memory + off, len);
    return 0;
}
static int write_mem(pid_t pid, uintptr_t addr, const void *buf, size_t len) {
    (void)pid; write_calls++;
    if (fail_write) return -1;
    if (fail_second_write && write_calls == 2) return -1;
    uintptr_t off = addr - (uintptr_t)region_base - 0x43B44;
    if (off + len > sizeof memory) return -1;
    memcpy(memory + off, buf, len);
    if (fail_after_write && write_calls == 1) return -1;
    return 0;
}
static void reset(const unsigned char *ctx) {
    memset(memory, 0xcc, sizeof memory);
    memcpy(memory, ctx, 32);
    find_calls = region_calls = read_calls = write_calls = 0;
    fail_find = fail_region = fail_read = fail_write = fail_verify_read = 0;
}
static void dump(const char *name, const struct rp_admission_result *r) {
    char json[1024];
    if (rp_admission_json(r, json, sizeof json) != 0) { puts("{}"); return; }
    printf("%.*s,\"scenario\":\"%s\",\"writes\":%d,\"reads\":%d,\"memory\":\"",
           (int)strlen(json) - 1, json, name, write_calls, read_calls);
    for (unsigned i = 0; i < 32; i++) printf("%02x", memory[i]);
    puts("\"}");
}
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    struct rp_admission_ops ops = {find_process, region_find, read_mem, write_mem};
    struct rp_admission_result r;
    unsigned char patched[32];
    memcpy(patched, stock, 32);
    patched[7] = patched[8] = patched[13] = patched[14] = 0x90;
    const char *name = argv[1];
    if (!strcmp(name, "apply-stock")) reset(stock);
    else if (!strcmp(name, "apply-patched")) reset(patched);
    else if (!strcmp(name, "apply-mismatch")) { reset(stock); memory[3] ^= 0xff; }
    else if (!strcmp(name, "apply-no-daemon")) { reset(stock); fail_find = 1; }
    else if (!strcmp(name, "apply-write-fails")) { reset(stock); fail_write = 1; }
    else if (!strcmp(name, "apply-verify-fails")) { reset(stock); fail_verify_read = 1; }
    else if (!strcmp(name, "apply-second-write-fails")) { reset(stock); fail_second_write = 1; }
    else if (!strcmp(name, "restore-second-write-fails")) { reset(patched); fail_second_write = 1; }
    else if (!strcmp(name, "apply-protection-restore-fails")) { reset(stock); fail_after_write = 1; }
    else if (!strcmp(name, "apply-verify-mismatch")) { reset(stock); corrupt_verify = 1; }
    else if (!strcmp(name, "apply-partial")) { reset(stock); memory[7] = memory[8] = 0x90; }
    else if (!strcmp(name, "apply-small-region")) { reset(stock); region_size = 0x43B60; }
    else if (!strcmp(name, "check-stock")) reset(stock);
    else if (!strcmp(name, "check-patched")) reset(patched);
    else if (!strcmp(name, "check-unknown")) { reset(stock); memory[20] ^= 0xff; }
    else if (!strcmp(name, "restore-patched")) reset(patched);
    else if (!strcmp(name, "restore-stock")) reset(stock);
    else if (!strcmp(name, "restore-mismatch")) { reset(patched); memory[4] ^= 0xff; }
    else return 2;
    enum rp_admission_mode mode = RP_ADMISSION_CHECK;
    if (!strncmp(name, "apply", 5)) mode = RP_ADMISSION_APPLY;
    if (!strncmp(name, "restore", 7)) mode = RP_ADMISSION_RESTORE;
    rp_admission(&ops, mode, &r);
    dump(name, &r);
    return 0;
}
