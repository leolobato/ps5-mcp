#include "RemotePlayBridge.h"
#include <chiaki/session.h>
#include <chiaki/opusdecoder.h>
#include <chiaki/time.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <poll.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <unistd.h>

struct RPRegistration { ChiakiRegist native; ChiakiLog log; RPRegistrationCallback callback; void *user; };
struct RPSession { ChiakiSession native; ChiakiOpusDecoder decoder; ChiakiLog log; RPCallbacks callbacks; void *user; uint32_t channels, rate; bool started; uint64_t last_idr_request_us; bool idr_requested;
    /* Last requested keyboard text, compared with the console's echo on the control thread. */
    pthread_mutex_t keyboard_lock; char keyboard_text[RP_KEYBOARD_TEXT_MAX + 1]; size_t keyboard_length; bool keyboard_pending; };
static pthread_once_t init_once = PTHREAD_ONCE_INIT;
static int init_error;
static void initialize(void) { init_error = chiaki_lib_init(); }
static void discard_log(ChiakiLogLevel level, const char *message, void *user) { (void)level; (void)message; (void)user; }
static void quiet_log(ChiakiLog *log) { *log = (ChiakiLog){ .level_mask = 0, .cb = discard_log }; }
static void wipe(void *ptr, size_t size) { volatile unsigned char *p = ptr; while(size--) *p++ = 0; }
static bool numeric_host(const char *host) { struct in6_addr address; return host && (inet_pton(AF_INET, host, &address)==1 || inet_pton(AF_INET6, host, &address)==1); }
static void registration_event(ChiakiRegistEvent *event, void *user) {
    RPRegistration *r = user;
    if(event->type != CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS || !event->registered_host) {
        r->callback(event->type == CHIAKI_REGIST_EVENT_TYPE_FINISHED_CANCELED ? RP_ERROR_CANCELED : CHIAKI_ERR_INVALID_RESPONSE, NULL, r->user); return;
    }
    ChiakiRegisteredHost *host = event->registered_host;
    RPRegistrationResult result = {0};
    memcpy(result.console_mac, host->server_mac, 6);
    memcpy(result.nickname, host->server_nickname, 32);
    memcpy(result.registration_key, host->rp_regist_key, 16);
    memcpy(result.rp_key, host->rp_key, 16);
    r->callback(0, &result, r->user);
    wipe(&result, sizeof(result));
}
RPRegistration *rp_registration_create(const char *host, const uint8_t account_id[8], uint32_t pin, RPRegistrationCallback callback, void *user, int *error) {
    if(error) *error = RP_ERROR_INVALID;
    if(!numeric_host(host) || !account_id || pin > 99999999 || !callback) return NULL;
    pthread_once(&init_once, initialize);
    if(init_error) { if(error) *error=init_error; return NULL; }
    RPRegistration *r = calloc(1, sizeof(*r));
    if(!r) { if(error) *error=CHIAKI_ERR_MEMORY; return NULL; }
    quiet_log(&r->log); r->callback=callback; r->user=user;
    ChiakiRegistInfo info = { .target=CHIAKI_TARGET_PS5_1, .host=host, .pin=pin, .broadcast=false };
    memcpy(info.psn_account_id, account_id, 8);
    int err = chiaki_regist_start(&r->native, &r->log, &info, registration_event, r);
    wipe(&info, sizeof(info));
    if(error) *error=err;
    if(err) { wipe(r,sizeof(*r)); free(r); return NULL; }
    return r;
}
void rp_registration_destroy(RPRegistration *r) { if(!r) return; chiaki_regist_stop(&r->native); chiaki_regist_fini(&r->native); wipe(r,sizeof(*r)); free(r); }

/* Connected UDP sockets accept packets only from the requested console endpoint. */
static int verify_identity(const char *host, const uint8_t expected[6], RPCallbacks cb, void *user) {
    struct addrinfo hints={.ai_family=AF_UNSPEC,.ai_socktype=SOCK_DGRAM,.ai_flags=AI_NUMERICHOST}, *address=NULL;
    if(getaddrinfo(host,"9302",&hints,&address)) return RP_ERROR_INVALID;
    int fd=socket(address->ai_family, SOCK_DGRAM, 0), result=RP_ERROR_TIMEOUT;
    if(fd < 0 || connect(fd,address->ai_addr,address->ai_addrlen)) { if(fd>=0) close(fd); freeaddrinfo(address); return CHIAKI_ERR_NETWORK; }
    freeaddrinfo(address);
    const char request[]="SRCH * HTTP/1.1\ndevice-discovery-protocol-version:00030010\n";
    if(send(fd,request,sizeof(request)-1,0)<0) { close(fd); return CHIAKI_ERR_NETWORK; }
    for(int attempt=0; attempt<30; attempt++) {
        if(cb.cancelled && cb.cancelled(user)) { result=RP_ERROR_CANCELED; break; }
        struct pollfd p={.fd=fd,.events=POLLIN};
        int status=poll(&p,1,50);
        if(status<0) { result=CHIAKI_ERR_NETWORK; break; }
        if(!status) continue;
        char response[2048]; ssize_t length=recv(fd,response,sizeof(response)-1,0);
        if(length<=0) { result=CHIAKI_ERR_NETWORK; break; }
        response[length]=0;
        bool ps5=false, identity=false, duplicate=false;
        char *cursor=response, *line=strsep(&cursor,"\n");
        if(!line || (strncmp(line,"HTTP/1.1 200 ",13) && strncmp(line,"HTTP/1.1 620 ",13))) { result=RP_ERROR_IDENTITY; break; }
        while((line=strsep(&cursor,"\n"))) {
            size_t len=strlen(line); if(len && line[len-1]=='\r') line[--len]=0;
            if(!strncmp(line,"host-type:",10)) ps5=!strcmp(line+10,"PS5");
            if(!strncmp(line,"host-id:",8)) {
                if(identity) duplicate=true;
                const char *hex=line+8; uint8_t mac[6];
                if(strlen(hex)!=12) { duplicate=true; continue; }
                bool valid=true;
                for(int i=0;i<6;i++) { char pair[3]={hex[i*2],hex[i*2+1],0}, *end; unsigned long value=strtoul(pair,&end,16); if(*end || end==pair || strspn(pair,"0123456789abcdefABCDEF")!=2) valid=false; mac[i]=(uint8_t)value; }
                identity=valid && !memcmp(mac,expected,6);
                if(!identity) duplicate=true;
            }
        }
        result=ps5 && identity && !duplicate ? 0 : RP_ERROR_IDENTITY; break;
    }
    close(fd); return result;
}
static bool video_sample(uint8_t *bytes, size_t size, int32_t lost, bool recovered, void *user) {
    (void)recovered; RPSession *s=user;
    bool accepted=s->callbacks.video && s->callbacks.video(bytes,size,lost,s->user);
    if(!accepted && (!s->callbacks.cancelled || !s->callbacks.cancelled(s->user))) {
        /* Chiaki only marks the reference as lost on callback rejection. Its
         * automatic IDR option covers FEC failure, so decoder rejection needs
         * an explicit request. This callback runs on the video receiver thread.
         * Throttle attempts (including failed sends) to one per second. */
        uint64_t now=chiaki_time_now_monotonic_us();
        if(!s->idr_requested || now-s->last_idr_request_us >= 1000000) {
            s->idr_requested=true;
            s->last_idr_request_us=now;
            chiaki_session_request_idr(&s->native);
        }
    }
    return accepted;
}
static void audio_settings(uint32_t channels, uint32_t rate, void *user) { RPSession *s=user; s->channels=channels; s->rate=rate; }
static void audio_frame(int16_t *pcm, size_t count, void *user) { RPSession *s=user; if(s->callbacks.audio && s->channels && s->rate) s->callbacks.audio(pcm,count,s->channels,s->rate,s->user); }
static void keyboard_event(RPSession *s, RPKeyboardEvent kind, const char *text) {
    if(kind == RP_KEYBOARD_TEXT_CONFIRMED) {
        pthread_mutex_lock(&s->keyboard_lock);
        size_t length = text ? strlen(text) : 0;
        bool same = s->keyboard_pending && length == s->keyboard_length && !memcmp(text ? text : "", s->keyboard_text, length);
        if(!same) kind = RP_KEYBOARD_TEXT_DIFFERS;
        pthread_mutex_unlock(&s->keyboard_lock);
    }
    if(s->callbacks.keyboard) s->callbacks.keyboard(kind, s->user);
}
static void session_event(ChiakiEvent *event, void *user) {
    RPSession *s=user;
    switch(event->type) {
        case CHIAKI_EVENT_KEYBOARD_OPEN: keyboard_event(s, RP_KEYBOARD_OPENED, NULL); return;
        case CHIAKI_EVENT_KEYBOARD_TEXT_CHANGE: keyboard_event(s, RP_KEYBOARD_TEXT_CONFIRMED, event->keyboard.text_str); return;
        case CHIAKI_EVENT_KEYBOARD_REMOTE_CLOSE: keyboard_event(s, RP_KEYBOARD_CLOSED, NULL); return;
        default: break;
    }
    if(!s->callbacks.event) return;
    switch(event->type) {
        case CHIAKI_EVENT_CONNECTED: s->callbacks.event(RP_EVENT_CONNECTED,0,s->user); break;
        case CHIAKI_EVENT_QUIT: s->callbacks.event(RP_EVENT_DISCONNECTED,event->quit.reason,s->user); break;
        case CHIAKI_EVENT_LOGIN_PIN_REQUEST: s->callbacks.event(RP_EVENT_LOGIN_PIN_NEEDED,event->login_pin_request.pin_incorrect,s->user); break;
        default: break;
    }
}
RPSession *rp_session_create(const char *host, const uint8_t mac[6], const uint8_t registration_key[16], const uint8_t rp_key[16], bool enable_keyboard, RPCallbacks callbacks, void *user, int *error) {
    if(error) *error=RP_ERROR_INVALID;
    if(!numeric_host(host) || !mac || !registration_key || !rp_key) return NULL;
    int err=verify_identity(host,mac,callbacks,user);
    if(err) { if(error) *error=err; return NULL; }
    pthread_once(&init_once,initialize);
    if(init_error) { if(error) *error=init_error; return NULL; }
    RPSession *s=calloc(1,sizeof(*s)); if(!s) { if(error) *error=CHIAKI_ERR_MEMORY; return NULL; }
    quiet_log(&s->log); s->callbacks=callbacks; s->user=user;
    ChiakiConnectInfo info={.ps5=true,.host=host,.enable_idr_on_fec_failure=true,.packet_loss_max=0.05,.enable_keyboard=enable_keyboard};
    info.video_profile=(ChiakiConnectVideoProfile){.width=1920,.height=1080,.max_fps=60,.bitrate=15000,.codec=CHIAKI_CODEC_H264};
    memcpy(info.regist_key,registration_key,16); memcpy(info.morning,rp_key,16);
    err=chiaki_session_init(&s->native,&info,&s->log); wipe(&info,sizeof(info));
    if(error) *error=err;
    if(err) { wipe(s,sizeof(*s)); free(s); return NULL; }
    pthread_mutex_init(&s->keyboard_lock,NULL);
    chiaki_opus_decoder_init(&s->decoder,&s->log);
    chiaki_opus_decoder_set_cb(&s->decoder,audio_settings,audio_frame,s);
    ChiakiAudioSink sink; chiaki_opus_decoder_get_sink(&s->decoder,&sink);
    chiaki_session_set_audio_sink(&s->native,&sink);
    chiaki_session_set_video_sample_cb(&s->native,video_sample,s);
    chiaki_session_set_event_cb(&s->native,session_event,s);
    return s;
}
int rp_session_start(RPSession *s) { if(!s || s->started) return RP_ERROR_INVALID; int err=chiaki_session_start(&s->native); if(!err) s->started=true; return err; }
void rp_session_destroy(RPSession *s) { if(!s) return; if(s->started) { chiaki_session_stop(&s->native); chiaki_session_join(&s->native); } chiaki_session_fini(&s->native); chiaki_opus_decoder_fini(&s->decoder); pthread_mutex_destroy(&s->keyboard_lock); wipe(s,sizeof(*s)); free(s); }
int rp_session_set_buttons(RPSession *s, uint32_t buttons) {
    if(!s || !s->started || (buttons & ~(uint32_t)RP_BUTTON_PS)) return RP_ERROR_INVALID;
    ChiakiControllerState state; chiaki_controller_state_set_idle(&state);
    state.buttons = buttons;
    return chiaki_session_set_controller_state(&s->native, &state);
}
int rp_session_keyboard_set_text(RPSession *s, const char *text) {
    if(!s || !s->started || !text) return RP_ERROR_INVALID;
    size_t length = strlen(text);
    if(length > RP_KEYBOARD_TEXT_MAX) return RP_ERROR_INVALID;
    pthread_mutex_lock(&s->keyboard_lock);
    memcpy(s->keyboard_text, text, length + 1); s->keyboard_length = length; s->keyboard_pending = true;
    pthread_mutex_unlock(&s->keyboard_lock);
    return chiaki_session_keyboard_set_text(&s->native, text);
}
int rp_session_keyboard_close(RPSession *s, bool accept) {
    if(!s || !s->started) return RP_ERROR_INVALID;
    pthread_mutex_lock(&s->keyboard_lock);
    wipe(s->keyboard_text, sizeof(s->keyboard_text)); s->keyboard_length = 0; s->keyboard_pending = false;
    pthread_mutex_unlock(&s->keyboard_lock);
    return accept ? chiaki_session_keyboard_accept(&s->native) : chiaki_session_keyboard_reject(&s->native);
}
