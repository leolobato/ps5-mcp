/* PS5 Account Tools — in-process NP fake sign-in / sign-out (PS5).
 *
 * Logic mirrors earthonion/np-fake-signin's PS5 (-DPS5) path verbatim:
 * config.dat offsets, the language->region table, build_config() and
 * write_registry_state(). The UserService init/terminate and all PS4-only
 * paths (account.dat/token.dat, HMAC signing, ShellCore memory patch) are
 * dropped — UserService is already up (sys_lite) and none of the PS4 bits
 * apply on PS5. Operations target an explicit user id + name.
 */

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "npsignin.h"

/* Template byte arrays (each defined in its own single-TU header). */
#include "np_templates/auth_dat.h"
#include "np_templates/config_dat.h"


/* ------------------------------------------------------------------ *
 * SDK imports                                                          *
 * ------------------------------------------------------------------ */

int32_t sceSystemServiceParamGetInt(int32_t paramId, int32_t *value);

int32_t sceRegMgrSetInt(uint32_t key, int32_t value);
int32_t sceRegMgrSetStr(uint32_t key, const char *value, size_t size);
int32_t sceRegMgrGetInt(uint32_t key, int32_t *value);
int32_t sceRegMgrGetStr(uint32_t key, char *value, size_t size);
int32_t sceRegMgrGetBin(uint32_t key, void *value, size_t size);


/* Registry keys (base, slot 1). Per-slot = key + (slot-1)*65536. */
#define REG_KEY_USERNAME      125829632   /* offset 0x04, str 17 */
#define REG_KEY_ACCOUNT_ID    125830400   /* offset 0x100, bin 8 */
#define REG_KEY_EMAIL         125830656   /* offset 0x108, str 65 */
#define REG_KEY_NP_ENV        125874183   /* offset 0x177, str 17 */
#define REG_KEY_ONLINE_ID     125874188   /* offset 0x1AD, str 17 */
#define REG_KEY_COUNTRY       125874190   /* offset 0x1BE, str 3 */
#define REG_KEY_LANGUAGE      125874191   /* offset 0x1C1, str 6 */
#define REG_KEY_LOCALE        125874192   /* offset 0x1C7, str 36 */
#define REG_KEY_FLAG_1        125830144   /* offset 0x48, int */
#define REG_KEY_FLAG_2        125831168   /* offset 0x50, int */
#define REG_KEY_FLAG_3        125831424   /* offset 0x4C, int */
#define REG_KEY_FLAG_5C       125832960   /* offset 0x5C, int */
#define REG_KEY_FIELD_1F4     125874194   /* offset 0x1F4, int */
#define REG_KEY_SIGNIN_FLAG   125874185   /* offset 0x1F8, int - CRITICAL */
#define REG_KEY_FIELD_1FC     125874186   /* offset 0x1FC, int */
#define REG_KEY_NP_0xA4       125830912   /* offset 0xA4, int */
#define REG_KEY_NP_0xB4       125831936   /* offset 0xB4, int */
#define REG_KEY_NP_0xD0       125832704   /* offset 0xD0, int */
#define REG_KEY_NP_0xD4       125882625   /* offset 0xD4, int */
#define REG_KEY_NP_0xDC       125854723   /* offset 0xDC, int */
#define REG_KEY_NP_0xF4       125833216   /* offset 0xF4, int */
#define REG_KEY_EXT_0x1100    125874189   /* offset 0x1100, str 65 */
#define REG_KEY_EXT_0x1141    125874193   /* offset 0x1141, str 11 */
#define REG_KEY_EXT_0x114C    125874195   /* offset 0x114C, str 65 */

/* ------------------------------------------------------------------ *
 * Language -> region table (indices match sceSystemServiceParamGetInt  *
 * LANG values; anything out of range falls back to en-US).             *
 * ------------------------------------------------------------------ */

static const struct { const char *country, *lang, *locale; } REGIONS[] = {
  {"jp","ja","ja-JP"}, {"us","en","en-US"}, {"fr","fr","fr-FR"},
  {"es","es","es-ES"}, {"de","de","de-DE"}, {"it","it","it-IT"},
  {"nl","nl","nl-NL"}, {"pt","pt","pt-PT"}, {"ru","ru","ru-RU"},
  {"kr","ko","ko-KR"}, {"tw","zh","zh-TW"}, {"cn","zh","zh-CN"},
  {"fi","fi","fi-FI"}, {"se","sv","sv-SE"}, {"dk","da","da-DK"},
  {"no","no","no-NO"}, {"pl","pl","pl-PL"}, {"br","pt","pt-BR"},
  {"gb","en","en-GB"}, {"tr","tr","tr-TR"}, {"mx","es","es-MX"},
  {"sa","ar","ar-SA"}, {"ca","fr","fr-CA"}, {"cz","cs","cs-CZ"},
  {"hu","hu","hu-HU"}, {"gr","el","el-GR"}, {"ro","ro","ro-RO"},
  {"th","th","th-TH"}, {"vn","vi","vi-VN"}, {"id","id","id-ID"},
};
#define REGION_COUNT ((int)(sizeof(REGIONS)/sizeof(REGIONS[0])))


/* ------------------------------------------------------------------ *
 * Helpers (verbatim from upstream PS5 path)                            *
 * ------------------------------------------------------------------ */

static void
patch_str(unsigned char *buf, int offset, const char *str, int max_len) {
  memset(&buf[offset], 0, max_len);
  int len = (int)strlen(str);
  if(len > max_len - 1) len = max_len - 1;
  memcpy(&buf[offset], str, len);
}

static void
build_config(unsigned char *cfg, const char *username, const uint8_t *account_id) {
  /* cfg is pre-loaded with template + region overrides before this call. */
  patch_str(cfg, 0x04, username, 17);          /* username        */
  memcpy(&cfg[0x100], account_id, 8);           /* account_id      */
  patch_str(cfg, 0x1AD, username, 17);          /* online_id       */

  char country[3] = {0};
  memcpy(country, &cfg[0x1BE], 2);
  if(country[0] == 0) { country[0] = 'u'; country[1] = 's'; }

  char np_email[65] = {0};
  snprintf(np_email, sizeof(np_email),
           "%s@a8.%s.np.playstation.net", username, country);
  patch_str(cfg, 0x108,  np_email, 65);         /* email           */
  patch_str(cfg, 0x1100, np_email, 65);         /* np_email        */
}

static int
write_file(const char *path, const unsigned char *data, size_t len) {
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if(fd < 0) return -1;
  ssize_t written = write(fd, data, len);
  close(fd);
  return (written == (ssize_t)len) ? 0 : -1;
}

static void
write_np_files(const unsigned char *cfg, uint32_t userId) {
  char path[256];
  snprintf(path, sizeof(path), "/system_data/priv/home/%x/np", userId);
  mkdir(path, 0755);

  snprintf(path, sizeof(path), "/system_data/priv/home/%x/np/auth.dat", userId);
  write_file(path, auth_dat, sizeof(auth_dat));

  snprintf(path, sizeof(path), "/system_data/priv/home/%x/config.dat", userId);
  write_file(path, cfg, sizeof(config_dat));
}

static void
write_registry_state(const unsigned char *cfg, uint32_t off) {
  int32_t val;

  if(cfg[0x108] != 0)
    sceRegMgrSetStr(REG_KEY_EMAIL + off, (const char*)&cfg[0x108], 65);
  sceRegMgrSetStr(REG_KEY_ONLINE_ID + off, (const char*)&cfg[0x1AD], 17);
  sceRegMgrSetStr(REG_KEY_NP_ENV + off,    (const char*)&cfg[0x177], 17);
  sceRegMgrSetStr(REG_KEY_COUNTRY + off,   (const char*)&cfg[0x1BE], 3);
  sceRegMgrSetStr(REG_KEY_LANGUAGE + off,  (const char*)&cfg[0x1C1], 6);
  sceRegMgrSetStr(REG_KEY_LOCALE + off,    (const char*)&cfg[0x1C7], 36);

  memcpy(&val, &cfg[0x48],  4); sceRegMgrSetInt(REG_KEY_FLAG_1 + off, val);
  memcpy(&val, &cfg[0x4C],  4); sceRegMgrSetInt(REG_KEY_FLAG_3 + off, val);
  memcpy(&val, &cfg[0x50],  4); sceRegMgrSetInt(REG_KEY_FLAG_2 + off, val);
  memcpy(&val, &cfg[0x5C],  4); sceRegMgrSetInt(REG_KEY_FLAG_5C + off, val);
  memcpy(&val, &cfg[0x1F4], 4); sceRegMgrSetInt(REG_KEY_FIELD_1F4 + off, val);
  memcpy(&val, &cfg[0x1F8], 4); sceRegMgrSetInt(REG_KEY_SIGNIN_FLAG + off, val);
  memcpy(&val, &cfg[0x1FC], 4); sceRegMgrSetInt(REG_KEY_FIELD_1FC + off, val);
  memcpy(&val, &cfg[0xA4],  4); sceRegMgrSetInt(REG_KEY_NP_0xA4 + off, val);
  memcpy(&val, &cfg[0xB4],  4); sceRegMgrSetInt(REG_KEY_NP_0xB4 + off, val);
  memcpy(&val, &cfg[0xD0],  4); sceRegMgrSetInt(REG_KEY_NP_0xD0 + off, val);
  memcpy(&val, &cfg[0xD4],  4); sceRegMgrSetInt(REG_KEY_NP_0xD4 + off, val);
  memcpy(&val, &cfg[0xDC],  4); sceRegMgrSetInt(REG_KEY_NP_0xDC + off, val);
  memcpy(&val, &cfg[0xF4],  4); sceRegMgrSetInt(REG_KEY_NP_0xF4 + off, val);

  if(cfg[0x1100] != 0)
    sceRegMgrSetStr(REG_KEY_EXT_0x1100 + off, (const char*)&cfg[0x1100], 65);
  if(cfg[0x1141] != 0)
    sceRegMgrSetStr(REG_KEY_EXT_0x1141 + off, (const char*)&cfg[0x1141], 11);
  if(cfg[0x114C] != 0)
    sceRegMgrSetStr(REG_KEY_EXT_0x114C + off, (const char*)&cfg[0x114C], 65);
}


/* ------------------------------------------------------------------ *
 * Resolve a user's activation slot + status.                          *
 * ------------------------------------------------------------------ */

static int
find_slot(const char *name) {
  if(!name || !name[0]) return 0;
  for(int n = 1; n <= 16; n++) {
    uint32_t off = (uint32_t)(n - 1) * 65536u;
    char slot_name[32] = {0};
    sceRegMgrGetStr(REG_KEY_USERNAME + off, slot_name, sizeof(slot_name));
    if(slot_name[0] && !strcmp(slot_name, name)) return n;
  }
  return 0;
}

static void
fill_status(npsignin_result_t *out) {
  out->slot = find_slot(out->user_name);
  out->account_id = 0;
  out->activated = 0;
  out->signed_in = 0;
  if(out->slot <= 0) return;

  uint32_t off = (uint32_t)(out->slot - 1) * 65536u;
  uint64_t id = 0;
  sceRegMgrGetBin(REG_KEY_ACCOUNT_ID + off, &id, sizeof(id));
  out->account_id = id;

  /* "Activated" means the slot has a non-zero account id. We deliberately do
     NOT key this off the flag at 0x50: offline activation sets it to 0x1002,
     but a successful NP sign-in legitimately overwrites the same key with the
     template's signed-in value (0x6), which would otherwise make an active,
     signed-in account read as "not activated". The account id is the stable
     indicator. */
  out->activated = (id != 0);

  int32_t sf = 0;
  sceRegMgrGetInt(REG_KEY_SIGNIN_FLAG + off, &sf);
  out->signed_in = (sf != 0);
}

static void
init_result(npsignin_result_t *out, uint32_t uid, const char *name) {
  memset(out, 0, sizeof(*out));
  out->user_id = uid;
  snprintf(out->user_name, sizeof(out->user_name), "%s", name ? name : "");
}


/* ------------------------------------------------------------------ *
 * Public API                                                           *
 * ------------------------------------------------------------------ */

int
npsignin_status(uint32_t uid, const char *name, npsignin_result_t *out) {
  init_result(out, uid, name);
  fill_status(out);
  out->ok = 1;
  if(out->slot == 0)
    snprintf(out->message, sizeof(out->message), "no registry slot");
  else if(!out->activated)
    snprintf(out->message, sizeof(out->message), "not activated");
  else
    snprintf(out->message, sizeof(out->message),
             out->signed_in ? "signed in" : "signed out");
  return 0;
}

int
npsignin_signin(uint32_t uid, const char *name, npsignin_result_t *out) {
  init_result(out, uid, name);
  fill_status(out);

  if(out->slot == 0 || out->account_id == 0) {
    out->ok = 0;
    snprintf(out->message, sizeof(out->message),
             "not activated — activate this account first");
    return -1;
  }

  /* Region from system language. */
  int32_t sys_lang = -1;
  sceSystemServiceParamGetInt(1 /* LANG */, &sys_lang);
  int ridx = (sys_lang >= 0 && sys_lang < REGION_COUNT) ? sys_lang : 1;

  /* Local working copy of the template — no shared mutable state. */
  unsigned char cfg[sizeof(config_dat)];
  memcpy(cfg, config_dat, sizeof(config_dat));
  patch_str(cfg, 0x1BE, REGIONS[ridx].country, 3);
  patch_str(cfg, 0x1C1, REGIONS[ridx].lang, 6);
  patch_str(cfg, 0x1C7, REGIONS[ridx].locale, 36);

  uint8_t acct_id[8];
  memcpy(acct_id, &out->account_id, 8);
  build_config(cfg, out->user_name, acct_id);

  write_np_files(cfg, out->user_id);

  /* Flags/state to base slot, and to the per-slot mirror when slot > 1. */
  write_registry_state(cfg, 0);
  if(out->slot > 1)
    write_registry_state(cfg, (uint32_t)(out->slot - 1) * 65536u);

  out->ok = 1;
  out->signed_in = 1;
  snprintf(out->message, sizeof(out->message),
           "signed in as %s — reboot to apply", out->user_name);
  return 0;
}

int
npsignin_signout(uint32_t uid, const char *name, npsignin_result_t *out) {
  init_result(out, uid, name);
  fill_status(out);

  /* Reverse the sign-in registry state: zero the sign-in flag and the two
     adjacent state ints at base + per-slot keys. The offline-activation
     account id is left untouched (use Deactivate to clear it). */
  const uint32_t offs[2] = {
    0u,
    out->slot > 1 ? (uint32_t)(out->slot - 1) * 65536u : 0u,
  };
  int n = (offs[1] != offs[0]) ? 2 : 1;
  for(int i = 0; i < n; i++) {
    sceRegMgrSetInt(REG_KEY_SIGNIN_FLAG + offs[i], 0);
    sceRegMgrSetInt(REG_KEY_FIELD_1F4  + offs[i], 0);
    sceRegMgrSetInt(REG_KEY_FIELD_1FC  + offs[i], 0);
  }

  /* Remove the forged NP files. */
  char path[256];
  snprintf(path, sizeof(path),
           "/system_data/priv/home/%x/np/auth.dat", out->user_id);
  unlink(path);
  snprintf(path, sizeof(path),
           "/system_data/priv/home/%x/config.dat", out->user_id);
  unlink(path);

  out->ok = 1;
  out->signed_in = 0;
  snprintf(out->message, sizeof(out->message),
           "signed out %s — reboot to apply. Guaranteed sign-out: Settings > "
           "Users and Accounts > Other > Sign out.", out->user_name);
  return 0;
}
