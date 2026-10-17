/* SPDX-License-Identifier: GPL-3.0-only
 * Separate, conservative derivative of pinned PS5 Account Tools; see NOTICE.md. */
#ifndef RP_SETUP_H
#define RP_SETUP_H
#include <stddef.h>
#include <stdint.h>
#define RP_FILE_MAX 16384
#define RP_REG_COUNT 26
#define RP_PORT 6770

enum rp_kind { RP_INT, RP_STRING, RP_BINARY };
struct rp_value { uint32_t key; uint32_t kind, size; unsigned char data[65]; };
struct rp_account {
    uint32_t uid;
    int slot, foreground, activated, signed_in, verified;
    uint64_t id;
    char name[33];
};
struct rp_registry_step {
    uint32_t key, kind, size;
    int setter_called, readback_called;
    int32_t setter_status, readback_status;
    int first_difference, wanted_length, actual_length;
};
struct rp_result {
    int ok, partial, restored, no_op;
    int has_registry_error;
    uint32_t error_key, error_kind, error_size;
    int32_t error_status;
    char error_phase[32];
    struct rp_registry_step error_step, steps[RP_REG_COUNT];
    unsigned step_count;
    int trace_saved;
    char trace_path[256];
    char code[48], message[384], backup[256];
    struct rp_account account;
};
/* File read: 0 exists, 1 absent, -1 error; reject oversized/nonregular files.
 * Replacement writes must be atomic, checked, and durable before returning 0. */
struct rp_ops {
    int (*users)(uint32_t ids[4], uint32_t *foreground);
    int (*name)(uint32_t uid, char name[33]);
    int (*reg_get)(struct rp_value *value);
    int (*reg_set)(const struct rp_value *value);
    int (*file_read)(const char *path, unsigned char *data, size_t *size);
    int (*file_write)(const char *path, const unsigned char *data, size_t size);
    int (*file_remove)(const char *path);
    int (*mkdir)(const char *path, unsigned mode);
    int (*random)(void *data, size_t size);
    int (*language)(int *language);
    const char *home_root, *backup_root;
    int (*legacy_profile_enabled)(void);
};
int rp_inspect(const struct rp_ops *, struct rp_account accounts[4], int *count);
void rp_prepare(const struct rp_ops *, uint32_t uid, int slot, uint64_t expected_id,
                struct rp_result *result);
typedef int (*rp_registry_probe)(uint32_t key, unsigned kind, unsigned size);
int rp_restore_diagnostics(const struct rp_ops *, char *, size_t);
int rp_registry_diagnostics(const struct rp_ops *, rp_registry_probe, char *, size_t);
void rp_base64(uint64_t id, char out[13]);
int rp_parse_form(const char *form, uint32_t *uid, int *slot, uint64_t *id);
int rp_account_json(const struct rp_account *, char *out, size_t cap);
int rp_accounts_json(const struct rp_ops *, const char *firmware, char *out, size_t cap);
int rp_trace_json(const struct rp_result *, char *out, size_t cap);
int rp_result_json(const struct rp_result *, char *out, size_t cap);
#endif
