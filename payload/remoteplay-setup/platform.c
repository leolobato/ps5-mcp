/* SPDX-License-Identifier: GPL-3.0-only
 * Checked derivative of Account Tools sys_lite.c; see NOTICE.md. */
#include "setup.h"
#include "files.h"
#include "firmware.h"
#include <ps5/kernel.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
extern int sceUserServiceInitialize(void *);
extern int sceUserServiceGetForegroundUser(uint32_t *);
extern int sceUserServiceGetLoginUserIdList(uint32_t ids[4]);
extern int sceUserServiceGetUserName(int32_t,char *,size_t);
extern int sceSystemServiceParamGetInt(int32_t,int32_t *);
extern int sceRegMgrGetInt(uint32_t,int32_t *);
extern int sceRegMgrGetStr(uint32_t,char *,size_t);
extern int sceRegMgrGetBin(uint32_t,void *,size_t);
#ifndef RP_DIAGNOSTIC_ONLY
extern int sceRegMgrSetInt(uint32_t,int32_t);
extern int sceRegMgrSetStr(uint32_t,const char *,size_t);
extern int sceRegMgrSetBin(uint32_t,const void *,size_t);
#endif
static int users(uint32_t ids[4],uint32_t *fg) {
    if(sceUserServiceGetLoginUserIdList(ids)||sceUserServiceGetForegroundUser(fg)) return -1;
    for(int i=0;i<4;i++) if(ids[i]==UINT32_MAX || ids[i]==0x80000000) ids[i]=0;
    return *fg && *fg<0x80000000 ? 0 : -1;
}
static int name(uint32_t uid,char out[33]) { memset(out,0,33); return sceUserServiceGetUserName((int32_t)uid,out,33); }
static int reg_get(struct rp_value *v) {
    memset(v->data,0,sizeof(v->data));
    if(v->kind==RP_STRING) return sceRegMgrGetStr(v->key,(char *)v->data,v->size);
    if(v->kind==RP_BINARY) return sceRegMgrGetBin(v->key,v->data,v->size);
    int32_t n; int rc=sceRegMgrGetInt(v->key,&n); if(!rc) memcpy(v->data,&n,4); return rc;
}
uint32_t rp_platform_firmware_raw(void) { return kernel_get_fw_version(); }
static int legacy_profile_enabled(void) { return rp_supported_firmware(rp_platform_firmware_raw()); }
#ifndef RP_DIAGNOSTIC_ONLY
static int reg_set(const struct rp_value *v) {
    if(v->kind==RP_STRING) return sceRegMgrSetStr(v->key,(const char *)v->data,v->size);
    if(v->kind==RP_BINARY) return sceRegMgrSetBin(v->key,v->data,v->size);
    int32_t n; memcpy(&n,v->data,4); return sceRegMgrSetInt(v->key,n);
}
static int random_bytes(void *data,size_t size) { arc4random_buf(data,size); return 0; }
static int language(int *n) { return sceSystemServiceParamGetInt(1,n); }
const struct rp_ops rp_platform={users,name,reg_get,reg_set,rp_file_read,rp_file_write,
    rp_file_remove,rp_mkdir,random_bytes,language,"/system_data/priv/home","/data/remoteplay-setup",legacy_profile_enabled};
#else
const struct rp_ops rp_platform={users,name,reg_get,NULL,rp_file_read,NULL,NULL,NULL,NULL,NULL,
    "/system_data/priv/home","/data/remoteplay-setup",legacy_profile_enabled};
/* No values are returned or logged by the general registry status probe. */
int rp_platform_registry_probe(uint32_t key,unsigned kind,unsigned size) {
    unsigned char buffer[256]={0};
    if(size>sizeof(buffer)) return -1;
    if(kind==RP_STRING) return sceRegMgrGetStr(key,(char *)buffer,size);
    if(kind==RP_BINARY) return sceRegMgrGetBin(key,buffer,size);
    if(kind==RP_INT && size==4) { int32_t number; return sceRegMgrGetInt(key,&number); }
    return -1;
}
#endif
int rp_platform_init(char firmware[16]) {
    signal(SIGPIPE,SIG_IGN);
    pid_t pid=getpid(); uint8_t caps[16],attrs[32]={0}; memset(caps,0xff,16); attrs[0]=0x80;
    intptr_t root=kernel_get_root_vnode();
    if(pid<=0 || !kernel_get_proc(pid) || !root ||
       kernel_set_ucred_uid(pid,0) || kernel_set_ucred_ruid(pid,0) ||
       kernel_set_ucred_svuid(pid,0) || kernel_set_ucred_rgid(pid,0) ||
       kernel_set_ucred_svgid(pid,0) || kernel_set_proc_rootdir(pid,root) ||
       kernel_set_proc_jaildir(pid,root) || kernel_set_ucred_authid(pid,0x4801000000000013ULL) ||
       kernel_set_ucred_caps(pid,caps) || kernel_set_ucred_attrs(pid,attrs)) return -1;
    int rc=sceUserServiceInitialize(NULL);
    if(rc && (uint32_t)rc!=0x80960003) return -1;
    uint32_t fw=kernel_get_fw_version();
    snprintf(firmware,16,"%x.%02x",fw>>24,(fw>>16)&255);
    return 0;
}
