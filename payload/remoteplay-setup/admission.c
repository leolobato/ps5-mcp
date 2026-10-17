/* SPDX-License-Identifier: GPL-3.0-only
 * Per-boot Remote Play admission patch for offline-prepared accounts.
 *
 * fw 13.60 SceRemotePlay refuses session admission with internal 0x80fc1052
 * (application 0x80108b12) when the UserService property-7 validator reports
 * the target user as not admitted. On offline consoles that property is
 * daemon-computed and cannot be satisfied with account data. This module
 * patches the two failure branches after the validator so admission uses the
 * already-verified registry userId. The patch is in-memory only (per boot),
 * context-verified before any write, and reversible. */
#include "admission.h"
#include <stdio.h>
#include <string.h>

/* Module offsets within SceRemotePlay's main text mapping (stable across boots;
 * the mapping base itself varies). Derived from firmware 13.60 analysis. */
#define RP_ADM_CTX_OFF   0x43B44u
#define RP_ADM_JS_OFF    0x43B4Bu
#define RP_ADM_JE_OFF    0x43B51u
#define RP_ADM_CTX_LEN   32u

static const unsigned char rp_adm_ctx_stock[RP_ADM_CTX_LEN] = {
    0xb9,0x52,0x10,0xfc,0x80,             /* mov ecx, 0x80fc1052 */
    0x85,0xc0,                            /* test eax, eax */
    0x78,0x18,                            /* js   fail */
    0x80,0x7d,0xaf,0x00,                  /* cmp byte ptr [rbp-0x51], 0 */
    0x74,0x12,                            /* je   fail */
    0x8b,0x45,0x94,                       /* mov eax, [rbp-0x6c] */
    0x89,0x83,0x70,0x04,0x00,0x00,        /* mov [rbx+0x470], eax */
    0x83,0x4d,0x88,0x02,                  /* or dword ptr [rbp-0x78], 2 */
    0x41,0xb7,0x01,0xeb                   /* mov r15b, 1; jmp */
};
static const unsigned char rp_adm_nop[2] = { 0x90, 0x90 };

static void copy_state(const unsigned char *ctx, char out[RP_ADM_HEX_MAX]) {
    static const char hex[] = "0123456789abcdef";
    for (unsigned i = 0; i < RP_ADM_CTX_LEN && 2 * i + 1 < RP_ADM_HEX_MAX - 1; i++) {
        out[2 * i] = hex[ctx[i] >> 4];
        out[2 * i + 1] = hex[ctx[i] & 15];
    }
    out[2 * RP_ADM_CTX_LEN < RP_ADM_HEX_MAX - 1 ? 2 * RP_ADM_CTX_LEN : RP_ADM_HEX_MAX - 1] = 0;
}

static int is_stock(const unsigned char *ctx) {
    return memcmp(ctx, rp_adm_ctx_stock, RP_ADM_CTX_LEN) == 0;
}

static int is_patched(const unsigned char *ctx) {
    unsigned char want[RP_ADM_CTX_LEN];
    memcpy(want, rp_adm_ctx_stock, RP_ADM_CTX_LEN);
    want[7] = 0x90; want[8] = 0x90;
    want[13] = 0x90; want[14] = 0x90;
    return memcmp(ctx, want, RP_ADM_CTX_LEN) == 0;
}

static void fail(struct rp_admission_result *r, const char *code, const char *message) {
    r->ok = 0;
    snprintf(r->code, sizeof r->code, "%s", code);
    snprintf(r->message, sizeof r->message, "%s", message);
}

/* A failed write may have changed bytes or page protection. Retry restoration
 * through the same protection-restoring operation and verify the full context.
 * Only the two known branch locations are ever written. */
static void rollback(const struct rp_admission_ops *ops, pid_t pid, uint64_t base,
                     const unsigned char *original, struct rp_admission_result *r) {
    r->rollback_attempted = 1;
    int first = ops->write_mem(pid, (uintptr_t)base + RP_ADM_JS_OFF, original + 7, 2);
    int second = ops->write_mem(pid, (uintptr_t)base + RP_ADM_JE_OFF, original + 13, 2);
    unsigned char back[RP_ADM_CTX_LEN];
    if (ops->read_mem(pid, (uintptr_t)base + RP_ADM_CTX_OFF, back, sizeof back) == 0) {
        copy_state(back, r->after);
        r->rollback_verified = first == 0 && second == 0 && !memcmp(back, original, sizeof back);
    }
}

void rp_admission(const struct rp_admission_ops *ops, enum rp_admission_mode mode,
                  struct rp_admission_result *r) {
    memset(r, 0, sizeof *r);
    if (mode != RP_ADMISSION_CHECK && mode != RP_ADMISSION_APPLY && mode != RP_ADMISSION_RESTORE) {
        fail(r, "bad-mode", "unknown admission operation");
        return;
    }
    if (!ops || !ops->find_process || !ops->region_find || !ops->read_mem ||
        (!ops->write_mem && mode != RP_ADMISSION_CHECK)) {
        fail(r, "bad-ops", "operation table incomplete");
        return;
    }
    pid_t pid = ops->find_process("SceRemotePlay");
    if (pid <= 0) {
        fail(r, "no-daemon", "SceRemotePlay is not running");
        return;
    }
    r->pid = pid;
    uint64_t base = 0, size = 0;
    if (ops->region_find(pid, &base, &size) != 0 || !base || size < RP_ADM_CTX_OFF + RP_ADM_CTX_LEN ||
        base > UINTPTR_MAX - RP_ADM_CTX_OFF - RP_ADM_CTX_LEN) {
        fail(r, "no-text", "main text mapping not found or unexpectedly small");
        return;
    }
    r->base = base;
    unsigned char ctx[RP_ADM_CTX_LEN];
    if (ops->read_mem(pid, (uintptr_t)base + RP_ADM_CTX_OFF, ctx, sizeof ctx) != 0) {
        fail(r, "read-failed", "could not read the admission context");
        return;
    }
    copy_state(ctx, r->before);
    r->stock = is_stock(ctx);
    r->patched = is_patched(ctx);
    if (mode == RP_ADMISSION_CHECK) {
        r->ok = (r->stock || r->patched);
        snprintf(r->code, sizeof r->code, r->patched ? "patched" : r->stock ? "stock" : "unknown");
        snprintf(r->message, sizeof r->message, "context is %s",
                 r->patched ? "already patched" : r->stock ? "unpatched" : "unrecognized");
        return;
    }
    if (mode == RP_ADMISSION_APPLY) {
        if (r->patched) {
            r->ok = 1;
            r->already = 1;
            copy_state(ctx, r->after);
            snprintf(r->code, sizeof r->code, "no-op");
            snprintf(r->message, sizeof r->message, "already patched");
            return;
        }
        if (!r->stock) {
            fail(r, "context-mismatch", "admission context unrecognized; refusing to write");
            return;
        }
    } else { /* RP_ADMISSION_RESTORE */
        if (r->stock) {
            r->ok = 1;
            r->already = 1;
            copy_state(ctx, r->after);
            snprintf(r->code, sizeof r->code, "no-op");
            snprintf(r->message, sizeof r->message, "already stock");
            return;
        }
        if (!r->patched) {
            fail(r, "context-mismatch", "admission context unrecognized; refusing to write");
            return;
        }
    }
    unsigned char jumps[4];
    if (mode == RP_ADMISSION_APPLY) {
        memcpy(jumps, rp_adm_nop, 2);
        memcpy(jumps + 2, rp_adm_nop, 2);
    } else {
        jumps[0] = rp_adm_ctx_stock[7];  jumps[1] = rp_adm_ctx_stock[8];
        jumps[2] = rp_adm_ctx_stock[13]; jumps[3] = rp_adm_ctx_stock[14];
    }
    if (ops->write_mem(pid, (uintptr_t)base + RP_ADM_JS_OFF, jumps, 2) != 0 ||
        ops->write_mem(pid, (uintptr_t)base + RP_ADM_JE_OFF, jumps + 2, 2) != 0) {
        fail(r, "write-failed", "kernel write to the admission branches failed");
        rollback(ops, pid, base, ctx, r);
        return;
    }
    unsigned char back[RP_ADM_CTX_LEN];
    if (ops->read_mem(pid, (uintptr_t)base + RP_ADM_CTX_OFF, back, sizeof back) != 0) {
        fail(r, "verify-read-failed", "could not read back the patched context");
        rollback(ops, pid, base, ctx, r);
        return;
    }
    copy_state(back, r->after);
    if (mode == RP_ADMISSION_APPLY ? !is_patched(back) : !is_stock(back)) {
        fail(r, "verify-mismatch", "patched bytes did not verify");
        rollback(ops, pid, base, ctx, r);
        return;
    }
    r->ok = 1;
    r->changed = 1;
    snprintf(r->code, sizeof r->code,
             mode == RP_ADMISSION_APPLY ? "patched" : "restored");
    snprintf(r->message, sizeof r->message,
             mode == RP_ADMISSION_APPLY
                 ? "admission branches patched for this boot"
                 : "admission branches restored to stock");
}

int rp_admission_json(const struct rp_admission_result *r, char *out, size_t cap) {
    int n = snprintf(out, cap,
                     "{\"ok\":%d,\"pid\":%d,\"base\":\"0x%llx\",\"stock\":%d,"
                     "\"patched\":%d,\"already\":%d,\"changed\":%d,"
                     "\"code\":\"%s\",\"before\":\"%s\",\"after\":\"%s\","
                     "\"message\":\"%s\",\"rollbackAttempted\":%d,\"rollbackVerified\":%d}",
                     r->ok, r->pid, (unsigned long long)r->base, r->stock,
                     r->patched, r->already, r->changed, r->code, r->before,
                     r->after, r->message, r->rollback_attempted, r->rollback_verified);
    return n > 0 && (size_t)n < cap ? 0 : -1;
}
