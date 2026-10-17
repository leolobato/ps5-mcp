/* SPDX-License-Identifier: GPL-3.0-only */
#include "setup.h"
#include "build_info.h"
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static const char b64[]="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
void rp_base64(uint64_t id,char out[13]) {
    unsigned char raw[8]; memcpy(raw,&id,8);
    for(int i=0,j=0;i<8;i+=3,j+=4) {
        unsigned v=(unsigned)raw[i]<<16;
        if(i+1<8) v|=(unsigned)raw[i+1]<<8;
        if(i+2<8) v|=raw[i+2];
        out[j]=b64[(v>>18)&63]; out[j+1]=b64[(v>>12)&63];
        out[j+2]=b64[(v>>6)&63]; out[j+3]=i+2<8 ? b64[v&63] : '=';
    }
    out[12]=0;
}
static int decode_id(const char *s,uint64_t *id) {
    if(strlen(s)!=12 || s[11]!='=') return -1;
    unsigned char bytes[9]={0};
    for(int i=0;i<12;i+=4) {
        unsigned v=0;
        for(int k=0;k<4;k++) {
            const char *p=strchr(b64,s[i+k]);
            if(i+k==11 && s[i+k]=='=') v<<=6;
            else { if(!p || !s[i+k]) return -1; v=(v<<6)|(unsigned)(p-b64); }
        }
        bytes[i/4*3]=(v>>16)&255; bytes[i/4*3+1]=(v>>8)&255; bytes[i/4*3+2]=v&255;
    }
    memcpy(id,bytes,8); char canonical[13]; rp_base64(*id,canonical);
    return strcmp(canonical,s) ? -1 : 0;
}
static int hex(char c) {
    if(c>='0'&&c<='9') return c-'0';
    if(c>='a'&&c<='f') return c-'a'+10;
    if(c>='A'&&c<='F') return c-'A'+10;
    return -1;
}
static int unquote(const char *in,char *out,size_t cap) {
    size_t n=0;
    for(size_t i=0;in[i];i++) {
        unsigned char c=in[i];
        if(c=='%') {
            if(!in[i+1] || !in[i+2] || hex(in[i+1])<0 || hex(in[i+2])<0) return -1;
            c=(unsigned char)((hex(in[i+1])<<4)|hex(in[i+2])); i+=2;
        } else if(c=='+') c=' ';
        if(!c || n+1>=cap) return -1;
        out[n++]=(char)c;
    }
    out[n]=0; return 0;
}
static int decimal(const char *s,uint32_t *out) {
    uint64_t n=0;
    if(!*s || (*s=='0' && s[1])) return -1;
    for(;*s;s++) { if(*s<'0'||*s>'9') return -1; n=n*10+(*s-'0'); if(n>UINT32_MAX) return -1; }
    *out=(uint32_t)n; return 0;
}
int rp_parse_form(const char *form,uint32_t *uid,int *slot,uint64_t *id) {
    char buf[256]; if(strlen(form)>=sizeof(buf)) return -1; strcpy(buf,form);
    unsigned seen=0; char *cursor=buf;
    while(cursor && *cursor) {
        char *next=strchr(cursor,'&'); if(next) *next++=0;
        char *eq=strchr(cursor,'='); if(!eq) return -1; *eq++=0;
        char value[64]; if(unquote(eq,value,sizeof(value))) return -1;
        unsigned bit;
        if(!strcmp(cursor,"userId")) { bit=1; if(decimal(value,uid)||!*uid) return -1; }
        else if(!strcmp(cursor,"slot")) { uint32_t v; bit=2; if(decimal(value,&v)||v<1||v>16) return -1; *slot=(int)v; }
        else if(!strcmp(cursor,"expectedAccountIdB64")) { bit=4; if(decode_id(value,id)) return -1; }
        else return -1;
        if(seen&bit) return -1;
        seen|=bit; cursor=next;
        if(next && !*next) return -1;
    }
    return seen==7 ? 0 : -1;
}
static void escape(const char *s,char *out,size_t cap) {
    size_t n=0;
    for(;*s && n+7<cap;s++) {
        unsigned char c=*s;
        if(c=='"'||c=='\\') { out[n++]='\\'; out[n++]=c; }
        else if(c<32) { int m=snprintf(out+n,cap-n,"\\u%04x",c); n+=(size_t)m; }
        else out[n++]=c;
    }
    out[n]=0;
}
int rp_account_json(const struct rp_account *a,char *out,size_t cap) {
    char name[224],id[13]; escape(a->name,name,sizeof(name)); rp_base64(a->id,id);
    return snprintf(out,cap,"{\"userId\":%u,\"name\":\"%s\",\"slot\":%d,"
        "\"accountId\":\"0x%016llx\",\"accountIdB64\":\"%s\","
        "\"activated\":%s,\"signedIn\":%s,\"foreground\":%s,\"preparationVerified\":%s}",
        a->uid,name,a->slot,(unsigned long long)a->id,id,a->activated?"true":"false",
        a->signed_in?"true":"false",a->foreground?"true":"false",a->verified?"true":"false");
}
int rp_accounts_json(const struct rp_ops *ops,const char *firmware,char *out,size_t cap) {
    struct rp_account accounts[4]; int count;
    if(rp_inspect(ops,accounts,&count)) return snprintf(out,cap,
        "{\"ok\":false,\"helper\":\"ps5mcp-remoteplay-setup\",\"version\":1,"
        "\"buildId\":\"" RP_BUILD_ID "\",\"code\":\"inspection-failed\",\"message\":\"Account identity or registry reads could not be verified.\"}");
    size_t n=(size_t)snprintf(out,cap,"{\"ok\":true,\"helper\":\"ps5mcp-remoteplay-setup\","
        "\"version\":1,\"buildId\":\"" RP_BUILD_ID "\",\"firmware\":\"%s\",\"hardwareValidated\":false,"
        "\"capabilities\":[\"compare-before-write\",\"preserve-existing-id\",\"target-slot-only\","
        "\"durable-backup\",\"checked-readback\",\"session-auth\"],\"accounts\":[",firmware);
    for(int i=0;i<count;i++) {
        if(n>=cap) return -1;
        if(i) out[n++]=',';
        int m=rp_account_json(&accounts[i],out+n,cap-n); if(m<0 || (size_t)m>=cap-n) return -1; n+=(size_t)m;
    }
    if(n+3>cap) return -1; memcpy(out+n,"]}",3); return (int)n+2;
}
static int step_json(const struct rp_registry_step *step,char *out,size_t cap) {
    return snprintf(out,cap,"{\"key\":%u,\"kind\":%u,\"size\":%u,\"setterCalled\":%s,"
        "\"setterStatus\":%d,\"setterStatusHex\":\"0x%08x\",\"readbackCalled\":%s,"
        "\"readbackStatus\":%d,\"readbackStatusHex\":\"0x%08x\","
        "\"firstDifference\":%d,\"wantedStringLength\":%d,\"actualStringLength\":%d}",
        step->key,step->kind,step->size,step->setter_called?"true":"false",step->setter_status,(uint32_t)step->setter_status,
        step->readback_called?"true":"false",step->readback_status,(uint32_t)step->readback_status,
        step->first_difference,step->wanted_length,step->actual_length);
}
static int registry_error_json(const struct rp_result *r,char *out,size_t cap) {
    const struct rp_registry_step *step=&r->error_step;
    return snprintf(out,cap,"{\"present\":%s,\"phase\":\"%s\",\"key\":%u,\"kind\":%u,\"size\":%u,"
        "\"returnStatus\":%d,\"returnStatusHex\":\"0x%08x\","
        "\"setterCalled\":%s,\"setterStatus\":%d,\"setterStatusHex\":\"0x%08x\","
        "\"readbackCalled\":%s,\"readbackStatus\":%d,\"readbackStatusHex\":\"0x%08x\","
        "\"firstDifference\":%d,\"wantedStringLength\":%d,\"actualStringLength\":%d}",
        r->has_registry_error?"true":"false",r->error_phase,r->error_key,r->error_kind,r->error_size,
        r->error_status,(uint32_t)r->error_status,step->setter_called?"true":"false",
        step->setter_status,(uint32_t)step->setter_status,step->readback_called?"true":"false",
        step->readback_status,(uint32_t)step->readback_status,step->first_difference,step->wanted_length,step->actual_length);
}
int rp_trace_json(const struct rp_result *r,char *out,size_t cap) {
    char error[1024]; registry_error_json(r,error,sizeof(error));
    int n=snprintf(out,cap,"{\"helper\":\"ps5mcp-remoteplay-setup\",\"buildId\":\"" RP_BUILD_ID "\","
        "\"ok\":%s,\"code\":\"%s\",\"partialWrites\":%s,\"restored\":%s,\"registryError\":%s,\"steps\":[",
        r->ok?"true":"false",r->code,r->partial?"true":"false",r->restored?"true":"false",error);
    if(n<0 || (size_t)n>=cap) return -1;
    size_t used=(size_t)n;
    for(unsigned i=0;i<r->step_count;i++) {
        if(i) { if(used+1>=cap) return -1; out[used++]=','; }
        int added=step_json(&r->steps[i],out+used,cap-used);
        if(added<0 || (size_t)added>=cap-used) return -1;
        used+=(size_t)added;
    }
    if(used+3>cap) return -1; memcpy(out+used,"]}",3); return (int)used+2;
}
int rp_result_json(const struct rp_result *r,char *out,size_t cap) {
    char account[768],message[2304],backup[1024],error[1024],trace[1024];
    rp_account_json(&r->account,account,sizeof(account)); escape(r->message,message,sizeof(message)); escape(r->backup,backup,sizeof(backup));
    escape(r->trace_path,trace,sizeof(trace)); registry_error_json(r,error,sizeof(error));
    return snprintf(out,cap,"{\"ok\":%s,\"code\":\"%s\",\"message\":\"%s\","
        "\"partialWrites\":%s,\"restored\":%s,\"noOp\":%s,\"backupPath\":\"%s\","
        "\"tracePath\":\"%s\",\"traceSaved\":%s,"
        "\"requiresUserReboot\":false,\"liveServiceStateVerified\":false,\"account\":%s,\"registryError\":%s}",
        r->ok?"true":"false",r->code,message,r->partial?"true":"false",r->restored?"true":"false",
        r->no_op?"true":"false",backup,trace,r->trace_saved?"true":"false",account,error);
}
