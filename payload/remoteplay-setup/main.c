/* SPDX-License-Identifier: GPL-3.0-only
 * Single-request, bounded LAN setup API. Does not launch any console UI. */
#include "setup.h"
#include "admission_platform.h"
#include "build_info.h"
#include <arpa/inet.h>
#include <netinet/in.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/select.h>
#include <time.h>
#include <unistd.h>
extern const struct rp_ops rp_platform;
extern int rp_platform_init(char firmware[16]);
/* Deployment patches this unique 64-byte marker. Volatile prevents folding. */
static volatile char rp_auth_token[65] = "PS5MCP_REMOTEPLAY_SETUP_TOKEN_UNCONFIGURED_CHANGE_BEFORE_UPLOAD_";
static double rp_expires;
static int rp_shutdown, rp_attempted;
static double rp_now(void) {
    struct timespec now;
    if(clock_gettime(CLOCK_MONOTONIC,&now)) return -1;
    return (double)now.tv_sec + (double)now.tv_nsec/1000000000.;
}
static int rp_configured(void) {
    unsigned valid=1;
    for(int i=0;i<64;i++) { unsigned char c=rp_auth_token[i];
        valid &= (c>='0'&&c<='9') || (c>='a'&&c<='f'); }
    return valid && rp_auth_token[64]==0;
}
static int rp_authorized(const char *value) {
    unsigned difference=0;
    if(!rp_configured() || !value || strlen(value)!=71 || strncmp(value,"Bearer ",7)) return 0;
    for(int i=0;i<64;i++) difference |= (unsigned char)value[i+7] ^ (unsigned char)rp_auth_token[i];
    double now=rp_now();
    return difference==0 && now>=0 && now<rp_expires;
}
static int send_all(int fd,const char *buf,size_t len) {
    while(len) { ssize_t n=send(fd,buf,len,0); if(n<0&&errno==EINTR) continue;
        if(n<=0) return -1; buf+=n; len-=(size_t)n; }
    return 0;
}
static void reply(int fd,int status,const char *json) {
    char header[256];
    int n=snprintf(header,sizeof(header),"HTTP/1.1 %d %s\r\nContent-Type: application/json\r\n"
        "Content-Length: %zu\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n",
        status,status==200?"OK":status==409?"Conflict":"Error",strlen(json));
    if(!send_all(fd,header,(size_t)n)) (void)send_all(fd,json,strlen(json));
}
static void request(int fd,const char *firmware) {
    char buf[4608],out[8192]; size_t have=0;
    char *end=NULL;
    while(have<4096) {
        ssize_t n=recv(fd,buf+have,sizeof(buf)-have-1,0); if(n<=0) goto bad;
        have+=(size_t)n; buf[have]=0;
        if(memchr(buf,0,have)) goto bad;
        end=strstr(buf,"\r\n\r\n"); if(end) break;
    }
    if(!end || (size_t)(end-buf)>4092) goto bad;
    size_t header_size=(size_t)(end-buf)+4;
    *end=0;
    char method[12],path[80],version[16],extra;
    char *line=strstr(buf,"\r\n"); if(!line) goto bad; *line=0;
    if(sscanf(buf,"%11s %79s %15s %c",method,path,version,&extra)!=3 || strcmp(version,"HTTP/1.1")) goto bad;
    size_t length=0; int has_length=0,custom=0,form=0,has_auth=0;
    const char *authorization=NULL;
    for(char *p=line+2;*p;) {
        char *next=strstr(p,"\r\n"); if(next) *next=0;
        char *colon=strchr(p,':'); if(!colon) goto bad; *colon++=0;
        while(*colon==' '||*colon=='\t') colon++;
        if(!strcasecmp(p,"Origin")||!strcasecmp(p,"Transfer-Encoding")) goto bad;
        if(!strcasecmp(p,"Content-Length")) {
            if(has_length++ || !*colon) goto bad;
            for(char *c=colon;*c;c++) { if(*c<'0'||*c>'9') goto bad; length=length*10+(unsigned)(*c-'0'); if(length>255) goto bad; }
        } else if(!strcasecmp(p,"Authorization")) {
            if(has_auth++) goto bad; authorization=colon;
        } else if(!strcasecmp(p,"X-RemotePlay-Setup")) custom=!strcmp(colon,"1");
        else if(!strcasecmp(p,"Content-Type")) form=!strcmp(colon,"application/x-www-form-urlencoded");
        if(!next) break; p=next+2;
    }
    if(!rp_authorized(authorization)) {
        reply(fd,401,"{\"ok\":false,\"code\":\"unauthorized\",\"partialWrites\":false}"); return;
    }
    while(have<header_size+length) {
        ssize_t n=recv(fd,buf+have,sizeof(buf)-have-1,0); if(n<=0) goto bad; have+=(size_t)n;
    }
    if(have!=header_size+length || memchr(buf+header_size,0,length)) goto bad;
    buf[have]=0;
    if(!rp_authorized(authorization)) {
        reply(fd,401,"{\"ok\":false,\"code\":\"unauthorized\",\"partialWrites\":false}"); return;
    }
    if(!strcmp(method,"POST")&&!strcmp(path,"/api/shutdown")&&custom&&has_length&&!length) {
        rp_shutdown=1; reply(fd,200,"{\"ok\":true}"); return;
    }
    if(!strcmp(method,"GET")&&!strcmp(path,"/api/status")&&!length) {
        int n=snprintf(out,sizeof(out),"{\"ok\":true,\"helper\":\"ps5mcp-remoteplay-setup\",\"version\":1,"
            "\"buildId\":\"" RP_BUILD_ID "\",\"firmware\":\"%s\",\"accounts\":[],"
            "\"capabilities\":[\"compare-before-write\",\"preserve-existing-id\",\"target-slot-only\","
            "\"durable-backup\",\"checked-readback\",\"session-auth\"]}",firmware);
        if(n<0 || (size_t)n>=sizeof(out)) goto bad;
        reply(fd,200,out); return;
    }
    if(!strcmp(method,"GET")&&!strcmp(path,"/api/accounts")&&!length) {
        if(rp_accounts_json(&rp_platform,firmware,out,sizeof(out))<0) goto bad;
        reply(fd,200,out); return;
    }
    if(!strcmp(method,"POST")&&!strcmp(path,"/api/admission")&&has_length&&form) {
        char mode[8], request_id[33], trailing;
        if(sscanf(buf+header_size,"mode=%7[a-z]&requestId=%32[0-9a-f]%c",mode,request_id,&trailing)!=2 ||
           strlen(request_id)!=32) goto bad;
        enum rp_admission_mode operation;
        if(!strcmp(mode,"check")) operation=RP_ADMISSION_CHECK;
        else if(!strcmp(mode,"apply")&&custom) operation=RP_ADMISSION_APPLY;
        else if(!strcmp(mode,"restore")&&custom) operation=RP_ADMISSION_RESTORE;
        else goto bad;
        struct rp_admission_result result;
        if(strcmp(firmware,"13.60")) {
            memset(&result,0,sizeof result);
            snprintf(result.code,sizeof result.code,"unsupported-firmware");
        } else {
            (void)rp_admission_run(operation,&result);
        }
        char report[2048];
        if(rp_admission_json(&result,report,sizeof(report))) goto bad;
        int n=snprintf(out,sizeof(out),"%.*s,\"mode\":\"%s\",\"requestId\":\"%s\",\"buildId\":\"" RP_BUILD_ID "\"}",
            (int)strlen(report)-1,report,mode,request_id);
        if(n<0 || (size_t)n>=sizeof(out)) goto bad;
        reply(fd,result.ok?200:409,out); return;
    }
    if(!strcmp(method,"POST")&&!strcmp(path,"/api/prepare")&&has_length&&custom&&form) {
        uint32_t uid; int slot; uint64_t expected;
        if(rp_parse_form(buf+header_size,&uid,&slot,&expected)) goto bad;
        /* Registry/config semantics outside this initial target remain unknown. */
        if(strcmp(firmware,"13.60") || !rp_platform.legacy_profile_enabled ||
           !rp_platform.legacy_profile_enabled()) {
            reply(fd,409,"{\"ok\":false,\"code\":\"unsupported-firmware\",\"partialWrites\":false,"
                "\"message\":\"This helper only permits preparation on firmware 13.60; device validation is pending.\"}"); return;
        }
        if(rp_attempted) {
            reply(fd,409,"{\"ok\":false,\"code\":\"session-used\",\"partialWrites\":false,"
                "\"message\":\"Start a new helper session before another confirmed preparation attempt.\"}"); return;
        }
        rp_attempted=1;
        struct rp_result result; rp_prepare(&rp_platform,uid,slot,expected,&result);
        if(rp_result_json(&result,out,sizeof(out))<0) goto bad;
        reply(fd,result.ok?200:409,out); return;
    }
    reply(fd,404,"{\"ok\":false,\"code\":\"unsupported-route\"}"); return;
bad:
    reply(fd,400,"{\"ok\":false,\"code\":\"invalid-request\",\"partialWrites\":false}");
}
int main(void) {
    if(!rp_configured()) { fputs("Remote Play setup: unconfigured session.\n",stderr); return 1; }
    double started=rp_now(); if(started<0) return 1; rp_expires=started+900;
    char firmware[16];
    if(rp_platform_init(firmware)) { fputs("Remote Play setup: privilege/service initialization failed.\n",stderr); return 1; }
    int server=socket(AF_INET,SOCK_STREAM,0); if(server<0) return 1;
    int yes=1; if(setsockopt(server,SOL_SOCKET,SO_REUSEADDR,&yes,sizeof(yes))) { close(server); return 1; }
    struct sockaddr_in address={0}; address.sin_family=AF_INET; address.sin_port=htons(RP_PORT); address.sin_addr.s_addr=htonl(INADDR_ANY);
    if(bind(server,(struct sockaddr *)&address,sizeof(address))||listen(server,4)) { close(server); return 1; }
    puts("Remote Play setup helper v1 listening on port 6770 (read-only until explicit POST).");
    while(!rp_shutdown) {
        double remaining=rp_expires-rp_now();
        if(remaining<=0 || remaining>900) break;
        fd_set readfds; FD_ZERO(&readfds); FD_SET(server,&readfds);
        struct timeval available={(time_t)remaining,(suseconds_t)((remaining-(time_t)remaining)*1000000)};
        int ready=select(server+1,&readfds,NULL,NULL,&available);
        if(!ready) break;
        if(ready<0) { if(errno==EINTR) continue; close(server); return 1; }
        int client=accept(server,NULL,NULL); if(client<0) { if(errno==EINTR) continue; close(server); return 1; }
        struct timeval timeout={3,0};
        if(!setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout)) &&
           !setsockopt(client,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout))) request(client,firmware);
        close(client);
    }
    close(server); return 0;
}
