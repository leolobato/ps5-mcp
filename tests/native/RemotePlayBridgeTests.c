/* Deterministic lifecycle backend using the pinned Chiaki headers. */
#include "RemotePlayBridge.h"
#include <chiaki/session.h>
#include <chiaki/opusdecoder.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>

static int stage, fail_init, fail_start, fail_registration;
static bool expect_keyboard = true;
static uint32_t sent_buttons = 0xffffffff; static int16_t sent_left_x = 1;
static char sent_text[2048]; static int keyboard_closes, keyboard_accepts;
static int idr_requests, idr_error;
static uint64_t now_us = 1000000;
uint64_t chiaki_time_now_monotonic_us(void) { return now_us; }
static const char *discovery_reply="HTTP/1.1 200 Ok\nhost-type:PS5\nhost-id:010203040506\n\n";
static ChiakiSession *native_session;
static ChiakiRegist *native_registration;
static ChiakiOpusDecoder *native_decoder;
ChiakiErrorCode chiaki_lib_init(void) { return CHIAKI_ERR_SUCCESS; }
ChiakiErrorCode chiaki_session_init(ChiakiSession *s, ChiakiConnectInfo *i, ChiakiLog *log) {
    assert(log && log->level_mask == 0 && log->cb);
    assert(i->ps5 && i->video_profile.codec == CHIAKI_CODEC_H264);
    assert(i->video_profile.width == 1920 && i->video_profile.height == 1080 && i->video_profile.max_fps == 60);
    assert(i->enable_idr_on_fec_failure && i->enable_keyboard == expect_keyboard && !i->enable_dualsense);
    assert(i->packet_loss_max == 0.05);
    native_session = s; stage = 1;
    return fail_init ? CHIAKI_ERR_MEMORY : CHIAKI_ERR_SUCCESS;
}
ChiakiErrorCode chiaki_session_start(ChiakiSession *s) { assert(s == native_session); stage = 2; return fail_start ? CHIAKI_ERR_NETWORK : CHIAKI_ERR_SUCCESS; }
void chiaki_controller_state_set_idle(ChiakiControllerState *state) { memset(state, 0, sizeof(*state)); }
ChiakiErrorCode chiaki_session_set_controller_state(ChiakiSession *s, ChiakiControllerState *state) { assert(s == native_session && stage == 2); sent_buttons = state->buttons; sent_left_x = state->left_x; return 0; }
ChiakiErrorCode chiaki_session_keyboard_set_text(ChiakiSession *s, const char *text) { assert(s == native_session && stage == 2); strcpy(sent_text, text); return 0; }
ChiakiErrorCode chiaki_session_keyboard_accept(ChiakiSession *s) { assert(s == native_session); keyboard_closes++; keyboard_accepts++; return 0; }
ChiakiErrorCode chiaki_session_keyboard_reject(ChiakiSession *s) { assert(s == native_session); keyboard_closes++; return 0; }
ChiakiErrorCode chiaki_session_request_idr(ChiakiSession *s) { assert(s == native_session && stage == 2); idr_requests++; return idr_error; }
ChiakiErrorCode chiaki_session_stop(ChiakiSession *s) { assert(s == native_session && stage == 2); stage = 3; return 0; }
ChiakiErrorCode chiaki_session_join(ChiakiSession *s) { assert(s == native_session && stage == 3); stage = 4; return 0; }
void chiaki_session_fini(ChiakiSession *s) { assert(s == native_session && (stage == 4 || stage == 1 || (stage == 2 && fail_start))); stage = 5; }
void chiaki_opus_decoder_init(ChiakiOpusDecoder *d, ChiakiLog *log) { (void)log; native_decoder = d; }
void chiaki_opus_decoder_get_sink(ChiakiOpusDecoder *d, ChiakiAudioSink *s) { (void)d; memset(s, 0, sizeof(*s)); }
void chiaki_opus_decoder_fini(ChiakiOpusDecoder *d) { assert(d == native_decoder && stage == 5); stage = 6; }
ChiakiErrorCode chiaki_regist_start(ChiakiRegist *r, ChiakiLog *log, const ChiakiRegistInfo *i, ChiakiRegistCb cb, void *user) {
    assert(log->level_mask == 0 && !i->broadcast && i->target == CHIAKI_TARGET_PS5_1);
    native_registration = r; r->cb = cb; r->cb_user = user; stage = 10; return fail_registration ? CHIAKI_ERR_THREAD : 0;
}
void chiaki_regist_stop(ChiakiRegist *r) { assert(r == native_registration && stage == 10); stage = 11; }
void chiaki_regist_fini(ChiakiRegist *r) { assert(r == native_registration && stage == 11); stage = 12; }
static int video_count, audio_count, event_count, registration_count;
static bool video_accepts, session_cancelled;
static bool session_is_cancelled(void *user) { assert(user); return session_cancelled; }
static bool canceled(void *user) { assert(user); return true; }
static bool video(const uint8_t *b, size_t n, int32_t lost, void *u) { assert(u && n == 4 && b[3] == 1 && lost == 2); video_count++; return video_accepts; }
static void audio(const int16_t *b, size_t n, uint32_t ch, uint32_t hz, void *u) { assert(u && b[0] == 5 && n == 2 && ch == 2 && hz == 48000); audio_count++; }
static void event(RPEvent e, int reason, void *u) { assert(u && e == RP_EVENT_DISCONNECTED && reason == CHIAKI_QUIT_REASON_CTRL_UNKNOWN); event_count++; }
static RPKeyboardEvent keyboard_events[8]; static int keyboard_count;
static void keyboard(RPKeyboardEvent e, void *u) { assert(u && keyboard_count < 8); keyboard_events[keyboard_count++] = e; }
static void registration(int err, const RPRegistrationResult *r, void *u) { assert(u && err == 0 && r && r->console_mac[0] == 9 && r->registration_key[15] == 8 && r->rp_key[15] == 7 && r->nickname[32] == 0); registration_count++; }
/* Identity lookup test seam lives outside production logic: loopback UDP console below. */
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
static void *console(void *arg) { int fd = *(int *)arg; char request[256]; struct sockaddr_storage peer; socklen_t len=sizeof(peer); assert(recvfrom(fd,request,sizeof(request),0,(struct sockaddr *)&peer,&len)>0); sendto(fd,discovery_reply,strlen(discovery_reply),0,(struct sockaddr *)&peer,len); return NULL; }
static RPSession *make_session(void) {
    int fd=socket(AF_INET,SOCK_DGRAM,0); assert(fd>=0); struct sockaddr_in addr={.sin_family=AF_INET,.sin_port=htons(9302),.sin_addr.s_addr=htonl(INADDR_LOOPBACK)}; assert(bind(fd,(struct sockaddr *)&addr,sizeof(addr))==0);
    pthread_t t; assert(!pthread_create(&t,NULL,console,&fd));
    uint8_t mac[]={1,2,3,4,5,6}, key[16]={0}; int err=0; RPCallbacks c={video,audio,event,session_is_cancelled,keyboard};
    RPSession *s=rp_session_create("127.0.0.1",mac,key,key,expect_keyboard,c,&stage,&err); pthread_join(t,NULL); close(fd); if(discovery_reply && strstr(discovery_reply,"host-id:010203040506") && !strstr(discovery_reply,"host-id:ffffffffffff")) assert(err==(fail_init?CHIAKI_ERR_MEMORY:0)); else assert(err==RP_ERROR_IDENTITY); return s;
}
int main(void) {
    uint8_t account[8]={0}; int err=0; RPRegistration *r=rp_registration_create("127.0.0.1",account,12,registration,&stage,&err); assert(r && !err);
    ChiakiRegisteredHost h={0}; memset(h.server_nickname,'x',32); h.server_mac[0]=9; h.rp_regist_key[15]=8; h.rp_key[15]=7; ChiakiRegistEvent re={CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS,&h}; native_registration->cb(&re,native_registration->cb_user); assert(registration_count==1); rp_registration_destroy(r); assert(stage==12);
    RPSession *s=make_session();
    assert(rp_session_set_buttons(s,RP_BUTTON_PS)==RP_ERROR_INVALID && sent_buttons==0xffffffff); // Not started: nothing reaches Chiaki.
    assert(rp_session_keyboard_set_text(s,"x")==RP_ERROR_INVALID && !sent_text[0]);
    assert(s && rp_session_start(s)==0); uint8_t bytes[]={0,0,0,1};
    /* PS only, on an otherwise idle state; any other button is refused. */
    assert(rp_session_set_buttons(s,RP_BUTTON_PS)==0 && sent_buttons==RP_BUTTON_PS && sent_left_x==0);
    assert(rp_session_set_buttons(s,RP_BUTTON_PS|1)==RP_ERROR_INVALID && sent_buttons==RP_BUTTON_PS);
    assert(rp_session_set_buttons(s,0)==0 && sent_buttons==0);
    /* Keyboard: the console's echo is compared in the bridge; only the verdict is delivered. */
    ChiakiEvent k={.type=CHIAKI_EVENT_KEYBOARD_OPEN}; k.keyboard.text_str="hunter2"; native_session->event_cb(&k,native_session->event_cb_user);
    assert(rp_session_keyboard_set_text(s,"héllo")==0 && !strcmp(sent_text,"héllo"));
    k.type=CHIAKI_EVENT_KEYBOARD_TEXT_CHANGE; k.keyboard.text_str="héllo"; native_session->event_cb(&k,native_session->event_cb_user);
    k.keyboard.text_str="héll"; native_session->event_cb(&k,native_session->event_cb_user);
    k.keyboard.text_str=NULL; native_session->event_cb(&k,native_session->event_cb_user);
    k.type=CHIAKI_EVENT_KEYBOARD_REMOTE_CLOSE; native_session->event_cb(&k,native_session->event_cb_user);
    assert(keyboard_count==5 && keyboard_events[0]==RP_KEYBOARD_OPENED && keyboard_events[1]==RP_KEYBOARD_TEXT_CONFIRMED
           && keyboard_events[2]==RP_KEYBOARD_TEXT_DIFFERS && keyboard_events[3]==RP_KEYBOARD_TEXT_DIFFERS && keyboard_events[4]==RP_KEYBOARD_CLOSED);
    assert(event_count==0); // Keyboard traffic never reaches the numeric event callback.
    assert(rp_session_keyboard_set_text(s,"")==0); k.type=CHIAKI_EVENT_KEYBOARD_TEXT_CHANGE; k.keyboard.text_str=NULL; native_session->event_cb(&k,native_session->event_cb_user);
    assert(keyboard_events[5]==RP_KEYBOARD_TEXT_CONFIRMED); // Clearing a field confirms against an empty echo.
    char longer[RP_KEYBOARD_TEXT_MAX+2]; memset(longer,'a',sizeof(longer)-1); longer[sizeof(longer)-1]=0;
    assert(rp_session_keyboard_set_text(s,longer)==RP_ERROR_INVALID && !strcmp(sent_text,""));
    assert(rp_session_keyboard_close(s,true)==0 && keyboard_accepts==1 && rp_session_keyboard_close(s,false)==0 && keyboard_closes==2);
    k.keyboard.text_str="";  native_session->event_cb(&k,native_session->event_cb_user);
    assert(keyboard_events[6]==RP_KEYBOARD_TEXT_DIFFERS); // After close nothing is pending.
    assert(!native_session->video_sample_cb(bytes,4,2,false,native_session->video_sample_cb_user));
    assert(idr_requests==1); // First decoder rejection explicitly requests an IDR.
    assert(!native_session->video_sample_cb(bytes,4,2,false,native_session->video_sample_cb_user));
    assert(idr_requests==1); // Repeated rejects cannot flood the console.
    now_us += 999999;
    assert(!native_session->video_sample_cb(bytes,4,2,false,native_session->video_sample_cb_user));
    assert(idr_requests==1);
    now_us += 1; idr_error=CHIAKI_ERR_NETWORK;
    assert(!native_session->video_sample_cb(bytes,4,2,false,native_session->video_sample_cb_user));
    assert(idr_requests==2);
    assert(!native_session->video_sample_cb(bytes,4,2,false,native_session->video_sample_cb_user));
    assert(idr_requests==2); // Failed requests are throttled too.
    now_us += 1000000; idr_error=0;
    assert(!native_session->video_sample_cb(bytes,4,2,false,native_session->video_sample_cb_user));
    assert(idr_requests==3);
    now_us += 1000000; video_accepts=true;
    assert(native_session->video_sample_cb(bytes,4,2,false,native_session->video_sample_cb_user));
    assert(idr_requests==3); // Successful decoding never asks for an IDR.
    now_us += 1000000; video_accepts=false; session_cancelled=true;
    assert(!native_session->video_sample_cb(bytes,4,2,false,native_session->video_sample_cb_user));
    assert(idr_requests==3); // Stop/cancellation never generates recovery traffic.
    session_cancelled=false;
    native_decoder->settings_cb(2,48000,native_decoder->cb_user); int16_t pcm[]={5,6,7,8}; native_decoder->frame_cb(pcm,2,native_decoder->cb_user); ChiakiEvent e={.type=CHIAKI_EVENT_QUIT,.quit={CHIAKI_QUIT_REASON_CTRL_UNKNOWN,"secret remote reason"}}; native_session->event_cb(&e,native_session->event_cb_user); assert(video_count==8 && audio_count==1 && event_count==1); rp_session_destroy(s); assert(stage==6);
    expect_keyboard=false; s=make_session(); rp_session_destroy(s); assert(stage==6); expect_keyboard=true;
    fail_start=1; s=make_session(); assert(rp_session_start(s)==CHIAKI_ERR_NETWORK); rp_session_destroy(s); assert(stage==6); fail_start=0;
    fail_init=1; assert(!make_session()); assert(stage==1); fail_init=0;
    discovery_reply="HTTP/1.1 200 Ok\nhost-type:PS5\nhost-id:ffffffffffff\n\n"; stage=99; assert(!make_session() && stage==99);
    discovery_reply="HTTP/1.1 200 Ok\nhost-type:PS5\nhost-id:010203040506\nhost-id:ffffffffffff\n\n"; stage=99; assert(!make_session() && stage==99);
    fail_registration=1; assert(!rp_registration_create("127.0.0.1",account,12,registration,&stage,&err) && err==CHIAKI_ERR_THREAD);
    assert(!rp_registration_create("localhost",account,12,registration,&stage,&err) && err==RP_ERROR_INVALID);
    assert(!rp_registration_create("127.0.0.1",account,100000000,registration,&stage,&err) && err==RP_ERROR_INVALID);
    uint8_t key[16]={0}, mac[6]={0}; RPCallbacks callbacks={0};
    assert(!rp_session_create("localhost",mac,key,key,true,callbacks,&stage,&err) && err==RP_ERROR_INVALID);
    callbacks.cancelled=canceled; stage=99;
    assert(!rp_session_create("127.0.0.1",mac,key,key,true,callbacks,&stage,&err) && err==RP_ERROR_CANCELED && stage==99);
    assert(rp_session_set_buttons(NULL,0)==RP_ERROR_INVALID && rp_session_keyboard_set_text(NULL,"")==RP_ERROR_INVALID && rp_session_keyboard_close(NULL,true)==RP_ERROR_INVALID);
    rp_session_destroy(NULL); rp_registration_destroy(NULL); puts("RemotePlayBridge lifecycle tests passed");
}
