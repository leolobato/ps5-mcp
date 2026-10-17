/* GPL-3.0 upstream region/config building, pinned source in NOTICE.md. */
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

