#ifndef PS5_REMOTE_PLAY_BRIDGE_H
#define PS5_REMOTE_PLAY_BRIDGE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Native handles are serialized by their owner. Destruction must never run on
 * a Chiaki callback thread. destroy stops, joins, then frees all callback state.
 * Callback buffers are immutable and borrowed only until callback return. */
typedef struct RPRegistration RPRegistration;
typedef struct RPSession RPSession;
enum { RP_ERROR_INVALID = -1, RP_ERROR_IDENTITY = -2, RP_ERROR_CANCELED = -3, RP_ERROR_TIMEOUT = -4 };
typedef struct {
    uint8_t console_mac[6];
    char nickname[33];
    uint8_t registration_key[16];
    uint8_t rp_key[16];
} RPRegistrationResult;
typedef void (*RPRegistrationCallback)(int error, const RPRegistrationResult *result, void *user);
typedef enum { RP_EVENT_CONNECTED, RP_EVENT_DISCONNECTED, RP_EVENT_LOGIN_PIN_NEEDED } RPEvent;
/* On-screen keyboard. Field text never crosses the bridge (it may be a password):
 * TEXT_CONFIRMED/TEXT_DIFFERS compare the console's echo with the last set_text. */
typedef enum { RP_KEYBOARD_OPENED, RP_KEYBOARD_TEXT_CONFIRMED, RP_KEYBOARD_TEXT_DIFFERS, RP_KEYBOARD_CLOSED } RPKeyboardEvent;
/* Remote Play controller buttons (Chiaki bit values). Only the PS button is exposed;
 * every other input stays on padd. */
enum { RP_BUTTON_PS = 1 << 15 };
enum { RP_KEYBOARD_TEXT_MAX = 1024 };
typedef struct {
    /* Return false after decoder rejection. The bridge requests an IDR, with
     * attempts limited to one per second; Chiaki also marks the reference lost. */
    bool (*video)(const uint8_t *annex_b, size_t size, int32_t frames_lost, void *user);
    void (*audio)(const int16_t *pcm, size_t samples_per_channel, uint32_t channels, uint32_t rate, void *user);
    /* Numeric reasons only: untrusted upstream strings may contain secrets. */
    void (*event)(RPEvent event, int reason, void *user);
    bool (*cancelled)(void *user);
    /* Optional; runs on the Chiaki control thread. */
    void (*keyboard)(RPKeyboardEvent event, void *user);
} RPCallbacks;
RPRegistration *rp_registration_create(const char *host, const uint8_t account_id[8], uint32_t pin, RPRegistrationCallback callback, void *user, int *error);
void rp_registration_destroy(RPRegistration *registration);
/* Numeric IPv4/IPv6 LAN address required. Unicast discovery verifies the MAC
 * at that address before any credentials are sent. Lookup polls cancellation
 * every 50ms and times out after 1500ms. Discovery identity is unauthenticated
 * (the console protocol provides no authenticated discovery). */
RPSession *rp_session_create(const char *host, const uint8_t expected_mac[6], const uint8_t registration_key[16], const uint8_t rp_key[16], bool enable_keyboard, RPCallbacks callbacks, void *user, int *error);
int rp_session_start(RPSession *session);
/* Owner-serialized like destroy. Started sessions only; others return RP_ERROR_INVALID.
 * buttons: 0 or RP_BUTTON_PS. The feedback sender repeats the state until changed. */
int rp_session_set_buttons(RPSession *session, uint32_t buttons);
/* Replaces the open field's text (UTF-8, no NUL, at most RP_KEYBOARD_TEXT_MAX bytes). */
int rp_session_keyboard_set_text(RPSession *session, const char *text);
int rp_session_keyboard_close(RPSession *session, bool accept);
void rp_session_destroy(RPSession *session);
#ifdef __cplusplus
}
#endif
#endif
