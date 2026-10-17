/* SPDX-License-Identifier: GPL-3.0-only
 * Account Tools registry/config derivative; see NOTICE.md and vendored source. */
#include "setup.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "build_info.h"
#include "../../third-party/account-tools/src/np_templates/auth_dat.h"
#include "../../third-party/account-tools/src/np_templates/config_dat.h"
#include "config.inc"

/* Each field is read, backed up, written, and read back through the same schema.
 * The sign-in flag is written last; no unconditional base-slot mirror. */
static const struct { uint32_t key, offset, size, kind; } fields[] = {
 {125830656,0x108,65,RP_STRING}, {125874188,0x1AD,17,RP_STRING},
 {125874183,0x177,17,RP_STRING}, {125874190,0x1BE,3,RP_STRING},
 {125874191,0x1C1,6,RP_STRING}, {125874192,0x1C7,36,RP_STRING},
 {125830144,0x48,4,RP_INT}, {125831424,0x4C,4,RP_INT},
 {125831168,0x50,4,RP_INT}, {125832960,0x5C,4,RP_INT},
 {125874194,0x1F4,4,RP_INT}, {125874186,0x1FC,4,RP_INT},
 {125830912,0xA4,4,RP_INT}, {125831936,0xB4,4,RP_INT},
 {125832704,0xD0,4,RP_INT}, {125882625,0xD4,4,RP_INT},
 {125854723,0xDC,4,RP_INT}, {125833216,0xF4,4,RP_INT},
 {125874189,0x1100,65,RP_STRING}, {125874193,0x1141,11,RP_STRING},
 {125874195,0x114C,65,RP_STRING}, {125830400,0x100,8,RP_BINARY},
 {125874185,0x1F8,4,RP_INT}
};
#define NFIELDS (sizeof(fields)/sizeof(fields[0]))
struct rp_snapshot {
    uint32_t magic, version, uid, slot;
    uint64_t old_id;
    uint32_t existed[2], size[2];
    struct rp_value registry[NFIELDS];
    /* Version 2: a nonzero status is an explicit unsupported-field marker,
     * never a substitute registry value. Only legacy flag1 may use it. */
    int32_t unsupported_status[NFIELDS];
    unsigned char files[2][RP_FILE_MAX];
};
/* 13.60 diagnostic evidence: legacy cfg0x48's registry ID is rejected by
 * GetInt/GetStr/GetBin on a fresh slot2 user; all other manifest keys read.
 * Preserve that exact unsupported status explicitly; never invent a value. */
static int legacy_absent(const struct rp_ops *ops,uint32_t key,int status) {
    return ops->legacy_profile_enabled && ops->legacy_profile_enabled() &&
        (uint32_t)status==0x800d0203 && key>=125830144 &&
        (key-125830144)%65536==0 && (key-125830144)/65536<16;
}
/* Bounded 13.60 experiment: preserve the exact six opaque NP integers grouped
 * by upstream. No mask, setter-normalization rule, or field semantics inferred.
 * The irregular D4/DC IDs and EXT_0x114C string are explicit members.
 * EXT_0x1100/0x1141 retain their ordinary checked writes. */
static int preserved_np_key(uint32_t key) {
    const uint32_t bases[]={125830912,125831936,125832704,125882625,125854723,125833216,125874195};
    for(size_t i=0;i<sizeof(bases)/sizeof(bases[0]);i++)
        if(key>=bases[i] && (key-bases[i])%65536==0 && (key-bases[i])/65536<16) return 1;
    return 0;
}
static int get(const struct rp_ops *ops, uint32_t key, unsigned kind,
               unsigned size, void *dst) {
    struct rp_value v = {.key=key,.kind=kind,.size=size};
    if(ops->reg_get(&v)) return -1;
    memcpy(dst,v.data,size); return 0;
}
static int identity(const struct rp_ops *ops, uint32_t uid, struct rp_account *a) {
    uint32_t ids[4], foreground;
    memset(a,0,sizeof(*a)); a->uid=uid;
    if(ops->users(ids,&foreground) || ops->name(uid,a->name)) return -1;
    if(!memchr(a->name,0,sizeof(a->name)) || !a->name[0] || strlen(a->name)>16) return -1;
    int found=0, matches=0;
    for(int i=0;i<4;i++) {
        if(ids[i]==uid) found++;
        if(ids[i] && ids[i]!=uid) {
            char n[33]={0};
            if(ops->name(ids[i],n) || !memchr(n,0,sizeof(n)) || !strcmp(n,a->name)) return -1;
        }
    }
    if(found!=1) return -1;
    for(int s=1;s<=16;s++) {
        char n[33]={0};
        if(get(ops,125829632+(s-1)*65536,RP_STRING,32,n) || !memchr(n,0,32)) return -1;
        if(!strcmp(n,a->name)) { a->slot=s; matches++; }
    }
    if(matches!=1) return -1;
    uint32_t off=(a->slot-1)*65536;
    int sf=0;
    if(get(ops,125830400+off,RP_BINARY,8,&a->id) ||
       get(ops,125874185+off,RP_INT,4,&sf)) return -1;
    a->foreground=(uid==foreground); a->activated=(a->id!=0); a->signed_in=(sf!=0);
    return 0;
}
static void paths(const struct rp_ops *ops, uint32_t uid, char out[2][256]) {
    snprintf(out[0],256,"%s/%x/np/auth.dat",ops->home_root,uid);
    snprintf(out[1],256,"%s/%x/config.dat",ops->home_root,uid);
}
static int file_equal(const struct rp_ops *ops,const char *path,
                      const unsigned char *data,size_t size) {
    unsigned char buf[RP_FILE_MAX]; size_t n=sizeof(buf);
    return ops->file_read(path,buf,&n)==0 && n==size && !memcmp(buf,data,n);
}
static int state_verified(const struct rp_ops *ops, const struct rp_account *a) {
    char path[2][256]; paths(ops,a->uid,path);
    unsigned char cfg[RP_FILE_MAX]; size_t n=sizeof(cfg);
    if(!a->activated || !a->signed_in ||
       ops->file_read(path[1],cfg,&n) || n!=sizeof(config_dat) ||
       memcmp(cfg+0x100,&a->id,8) || memcmp(cfg+4,a->name,strlen(a->name)+1) ||
       !file_equal(ops,path[0],auth_dat,sizeof(auth_dat))) return 0;
    for(size_t i=0;i<NFIELDS;i++) {
        struct rp_value v={.key=fields[i].key+(a->slot-1)*65536,
            .kind=fields[i].kind,.size=fields[i].size};
        int status=ops->reg_get(&v);
        if(legacy_absent(ops,v.key,status)) continue;
        if(status || memcmp(v.data,cfg+fields[i].offset,v.size)) return 0;
    }
    return 1;
}
int rp_inspect(const struct rp_ops *ops,struct rp_account accounts[4],int *count) {
    uint32_t ids[4],foreground; *count=0;
    if(ops->users(ids,&foreground)) return -1;
    for(int i=0;i<4;i++) if(ids[i]) {
        struct rp_account a;
        if(identity(ops,ids[i],&a)) return -1;
        a.verified=state_verified(ops,&a); accounts[(*count)++]=a;
    }
    return 0;
}
static int same_target(const struct rp_ops *ops,const struct rp_account *a,uint64_t id) {
    struct rp_account now;
    return !identity(ops,a->uid,&now) && now.foreground && now.slot==a->slot &&
        now.id==id && !strcmp(now.name,a->name);
}
static int reg_equal(const struct rp_ops *ops,const struct rp_value *wanted) {
    struct rp_value actual=*wanted;
    return !ops->reg_get(&actual) && !memcmp(actual.data,wanted->data,wanted->size);
}
static int snapshot_field_matches(const struct rp_ops *ops,const struct rp_snapshot *saved,size_t i) {
    if(!saved->unsupported_status[i]) return reg_equal(ops,&saved->registry[i]);
    struct rp_value probe=saved->registry[i];
    int status=ops->reg_get(&probe);
    return status==saved->unsupported_status[i] && legacy_absent(ops,probe.key,status);
}
/* Generic inspection accepts either supported profile state. A transaction must
 * also preserve whether this particular legacy field was supported at backup. */
static int legacy_transaction_stable(const struct rp_ops *ops,const struct rp_snapshot *saved,
                                     const unsigned char *cfg) {
    for(size_t i=0;i<NFIELDS;i++) if(fields[i].key==125830144) {
        if(saved->unsupported_status[i]) return snapshot_field_matches(ops,saved,i);
        struct rp_value expected=saved->registry[i];
        memcpy(expected.data,cfg+fields[i].offset,expected.size);
        return reg_equal(ops,&expected);
    }
    return 0;
}
static int restore(const struct rp_ops *ops,const struct rp_snapshot *saved,
                   const char path[2][256],size_t reg_attempts,int file_attempts,int preserve_np_profile) {
    int ok=1;
    /* Restore sign-in/registry state first, then files. Attempt every touched value
     * even if another restore fails. A failed setter can have changed its value. */
    while(reg_attempts) {
        --reg_attempts;
        if(saved->unsupported_status[reg_attempts]) continue;
        const struct rp_value *v=&saved->registry[reg_attempts];
        if(preserve_np_profile && preserved_np_key(v->key)) {
            if(!reg_equal(ops,v)) ok=0;
            continue;
        }
        if(!reg_equal(ops,v) && (ops->reg_set(v) || !reg_equal(ops,v))) ok=0;
    }
    for(int i=0;i<file_attempts;i++) {
        if(saved->existed[i]) {
            if(ops->file_write(path[i],saved->files[i],saved->size[i]) ||
               !file_equal(ops,path[i],saved->files[i],saved->size[i])) ok=0;
        } else {
            unsigned char b[RP_FILE_MAX]; size_t n=sizeof(b);
            if(ops->file_remove(path[i]) || ops->file_read(path[i],b,&n)!=1) ok=0;
        }
    }
    /* A preserved NP field can drift before its forward index. It must match the
     * backup before claiming restoration; never issue a compensating setter. */
    for(size_t i=0;i<NFIELDS;i++) if(preserve_np_profile && preserved_np_key(saved->registry[i].key) &&
        !reg_equal(ops,&saved->registry[i])) ok=0;
    return ok;
}
static void fail(struct rp_result *r,const char *code,const char *message) {
    snprintf(r->code,sizeof(r->code),"%s",code);
    snprintf(r->message,sizeof(r->message),"%s",message);
}
static int bounded_length(const unsigned char *data,unsigned size) {
    for(unsigned i=0;i<size;i++) if(!data[i]) return (int)i;
    return (int)size;
}
static int checked_registry_write(const struct rp_ops *ops,const struct rp_value *wanted,
                                  struct rp_registry_step *step) {
    memset(step,0,sizeof(*step)); step->key=wanted->key; step->kind=wanted->kind; step->size=wanted->size;
    step->first_difference=-1; step->wanted_length=step->actual_length=-1;
    if(wanted->kind==RP_STRING) step->wanted_length=bounded_length(wanted->data,wanted->size);
    step->setter_called=1; step->setter_status=(int32_t)ops->reg_set(wanted);
    if(step->setter_status) return 0;
    struct rp_value actual=*wanted; step->readback_called=1;
    step->readback_status=(int32_t)ops->reg_get(&actual);
    if(step->readback_status) return 0;
    if(wanted->kind==RP_STRING) step->actual_length=bounded_length(actual.data,actual.size);
    for(unsigned i=0;i<wanted->size;i++) if(actual.data[i]!=wanted->data[i]) {
        step->first_difference=(int)i; return 0;
    }
    return 1;
}
static void registry_write_failure(struct rp_result *r,const struct rp_registry_step *step) {
    r->has_registry_error=1; r->error_key=step->key; r->error_kind=step->kind; r->error_size=step->size;
    r->error_step=*step;
    const char *phase=step->setter_status ? "setter" : step->readback_status ? "readback-read" : "readback-compare";
    snprintf(r->error_phase,sizeof(r->error_phase),"%s",phase);
    r->error_status=step->setter_status ? step->setter_status : step->readback_status;
    fail(r,"registry-write","");
    snprintf(r->message,sizeof(r->message),
        "Registry %s failed: key=%u kind=%u size=%u setter=0x%08x readback=%s0x%08x diff=%d stringLengths=%d/%d.",
        phase,step->key,step->kind,step->size,(uint32_t)step->setter_status,
        step->readback_called ? "" : "not-called/",(uint32_t)step->readback_status,
        step->first_difference,step->wanted_length,step->actual_length);
}
static void save_trace(const struct rp_ops *ops,struct rp_result *r) {
    static unsigned serial;
    if(!ops->file_write || !ops->file_read) return;
    unsigned char probe[1];
    for(unsigned attempt=0;attempt<32;attempt++) {
        snprintf(r->trace_path,sizeof(r->trace_path),"%s/%x.%u.%u.trace.json",ops->backup_root,
                 r->account.uid,(unsigned)getpid(),++serial);
        size_t size=sizeof(probe);
        if(ops->file_read(r->trace_path,probe,&size)!=1) continue;
        char json[16384]; int n=rp_trace_json(r,json,sizeof(json));
        if(n>0 && n<(int)sizeof(json))
            r->trace_saved=!ops->file_write(r->trace_path,(unsigned char *)json,(size_t)n) &&
                file_equal(ops,r->trace_path,(unsigned char *)json,(size_t)n);
        return;
    }
    r->trace_path[0]=0;
}
void rp_prepare(const struct rp_ops *ops,uint32_t uid,int slot,uint64_t expected,
                struct rp_result *r) {
    memset(r,0,sizeof(*r));
    struct rp_account a;
    if(!uid || slot<1 || slot>16 || identity(ops,uid,&a) || !a.foreground || a.slot!=slot) {
        fail(r,"target-changed","Select the unique foreground account again."); return;
    }
    r->account=a;
    const int preserve_np_profile=ops->legacy_profile_enabled && ops->legacy_profile_enabled();
    if(a.id!=expected) { fail(r,"account-id-changed","Account ID changed; inspect again."); return; }
    if(state_verified(ops,&a)) {
        r->account.verified=1; r->ok=1; r->no_op=1;
        fail(r,"already-prepared","Persisted preparation is verified; no changes made."); return;
    }
    /* Never rewrite apparently signed-in accounts whose state we did not create. */
    if(a.signed_in) { fail(r,"existing-signin-state","Existing sign-in state needs manual review."); return; }
    int trace_enabled=0;
    struct rp_snapshot *saved=calloc(1,sizeof(*saved));
    if(!saved) { fail(r,"memory","Unable to allocate backup."); return; }
    saved->magic=0x52505331; saved->version=2; saved->uid=uid; saved->slot=slot; saved->old_id=a.id;
    char path[2][256]; paths(ops,uid,path);
    char marker[256]; snprintf(r->backup,sizeof(r->backup),"%s/%x.snapshot",ops->backup_root,uid);
    snprintf(marker,sizeof(marker),"%s/%x.state",ops->backup_root,uid);
    unsigned char prior[RP_FILE_MAX]; size_t prior_size=sizeof(prior);
    /* Any durable transaction marker blocks fresh mutations; process interruption
     * or external state changes require offline review of the original snapshot. */
    if(ops->file_read(marker,prior,&prior_size)!=1) {
        fail(r,"recovery-required","A previous transaction exists; review its backup before changes."); goto done;
    }
    for(size_t i=0;i<NFIELDS;i++) {
        struct rp_value *v=&saved->registry[i];
        v->key=fields[i].key+(slot-1)*65536; v->kind=fields[i].kind; v->size=fields[i].size;
        int status=ops->reg_get(v);
        if(legacy_absent(ops,v->key,status)) {
            saved->unsupported_status[i]=(int32_t)status; continue;
        }
        if(status) {
            r->has_registry_error=1; r->error_key=v->key; r->error_kind=v->kind;
            r->error_size=v->size; r->error_status=(int32_t)status;
            snprintf(r->error_phase,sizeof(r->error_phase),"backup-read");
            r->error_step.first_difference=r->error_step.wanted_length=r->error_step.actual_length=-1;
            fail(r,"backup-read","");
            snprintf(r->message,sizeof(r->message),
                "Registry backup read failed: key=%u kind=%u size=%u status=0x%08x (%d). No account writes.",
                v->key,v->kind,v->size,(uint32_t)status,(int32_t)status);
            goto done;
        }
    }
    for(int i=0;i<2;i++) {
        size_t n=sizeof(saved->files[i]); int rc=ops->file_read(path[i],saved->files[i],&n);
        if(rc<0) { fail(r,"backup-read","Account file backup read failed."); goto done; }
        saved->existed[i]=(rc==0); saved->size[i]=(rc==0 ? (uint32_t)n : 0);
    }
    /* Durable immutable backup exists before any account-state writes. */
    if(ops->mkdir(ops->backup_root,0700) ||
       ops->file_write(r->backup,(unsigned char *)saved,sizeof(*saved))) {
        fail(r,"backup-write","Unable to persist backup; account was not changed."); goto done;
    }
    /* Snapshot exceeds RP_FILE_MAX; read it back in the backend with an appropriately
     * sized buffer before claiming that backup creation succeeded. */
    struct rp_snapshot *check=malloc(sizeof(*check));
    size_t check_size=sizeof(*check);
    if(!check || ops->file_read(r->backup,(unsigned char *)check,&check_size) ||
       check_size!=sizeof(*saved) || memcmp(check,saved,sizeof(*saved))) {
        free(check); fail(r,"backup-readback","Backup readback failed; account was not changed."); goto done;
    }
    free(check); trace_enabled=1;
    if(ops->file_write(marker,(const unsigned char *)"pending\n",8)) {
        fail(r,"backup-write","Unable to persist transaction marker; account was not changed."); goto done;
    }
    uint64_t id=a.id;
    if(!id) {
        do { if(ops->random(&id,sizeof(id))) { fail(r,"random","Random account ID generation failed."); goto clean; } } while(!id);
    }
    int language;
    if(ops->language(&language) || language<0 || language>=REGION_COUNT) {
        fail(r,"language","System language could not be resolved."); goto clean;
    }
    unsigned char cfg[sizeof(config_dat)]; memcpy(cfg,config_dat,sizeof(cfg));
    patch_str(cfg,0x1BE,REGIONS[language].country,3);
    patch_str(cfg,0x1C1,REGIONS[language].lang,6);
    patch_str(cfg,0x1C7,REGIONS[language].locale,36);
    build_config(cfg,a.name,(const uint8_t *)&id);
    for(size_t i=0;i<NFIELDS;i++) if(preserve_np_profile && preserved_np_key(saved->registry[i].key))
        memcpy(cfg+fields[i].offset,saved->registry[i].data,fields[i].size);
    /* Compare again after backup, including every registry/file value to be replaced.
     * Registry API offers no atomic transaction; concurrent console changes remain a
     * device-validation concern and are disclosed in NOTICE.md. */
    if(!same_target(ops,&a,expected)) { fail(r,"target-changed","Account changed during backup."); goto clean; }
    for(size_t i=0;i<NFIELDS;i++) if(!snapshot_field_matches(ops,saved,i)) {
        fail(r,"target-changed","Registry changed during backup."); goto clean;
    }
    for(int i=0;i<2;i++) {
        size_t n=sizeof(prior); int rc=ops->file_read(path[i],prior,&n);
        if((saved->existed[i] && (rc || n!=saved->size[i] || memcmp(prior,saved->files[i],n))) ||
           (!saved->existed[i] && rc!=1)) { fail(r,"target-changed","Account files changed during backup."); goto clean; }
    }
    char np[256]; snprintf(np,sizeof(np),"%s/%x/np",ops->home_root,uid);
    if(ops->mkdir(np,0755)) { fail(r,"file-write","Unable to create target NP directory."); goto clean; }
    size_t reg_attempts=0; int file_attempts=0; uint64_t current_expected=expected;
    for(int i=0;i<2;i++) {
        file_attempts=i+1; r->partial=1;
        const unsigned char *data=i ? cfg : auth_dat; size_t n=i ? sizeof(cfg) : sizeof(auth_dat);
        if(ops->file_write(path[i],data,n) || !file_equal(ops,path[i],data,n)) {
            fail(r,"file-write","Account file write/readback failed."); goto rollback;
        }
    }
    for(size_t i=0;i<NFIELDS;i++) {
        if(saved->unsupported_status[i]) continue;
        struct rp_value v=saved->registry[i]; memcpy(v.data,cfg+fields[i].offset,v.size);
        if(preserve_np_profile && preserved_np_key(v.key)) {
            if(!reg_equal(ops,&saved->registry[i])) {
                fail(r,"target-changed","Preserved NP state changed during preparation."); goto rollback;
            }
            continue;
        }
        /* Preserve a nonzero account ID by never issuing even a redundant setter. */
        if(v.key==125830400+(uint32_t)(slot-1)*65536 && a.id) continue;
        if(!same_target(ops,&a,current_expected) || !reg_equal(ops,&saved->registry[i])) {
            fail(r,"target-changed","Foreground account changed during preparation."); goto rollback;
        }
        reg_attempts=i+1;
        struct rp_registry_step *step=&r->steps[r->step_count++];
        if(!checked_registry_write(ops,&v,step)) {
            registry_write_failure(r,step); goto rollback;
        }
        if(v.key==125830400+(uint32_t)(slot-1)*65536) current_expected=id;
    }
    if(identity(ops,uid,&r->account) || !r->account.foreground ||
       r->account.slot!=slot || r->account.id!=id || !state_verified(ops,&r->account) ||
       !legacy_transaction_stable(ops,saved,cfg)) {
        fail(r,"verify","Final persisted-state verification failed."); goto rollback;
    }
    if(ops->file_write(marker,(const unsigned char *)"complete\n",9)) {
        fail(r,"journal-write","Could not persist completion; restoring backup."); goto rollback;
    }
    r->ok=1; r->partial=0; r->account.verified=1;
    fail(r,"prepared","Persisted state verified. Pair and test streaming; service refresh is unverified."); goto done;
rollback:
    /* If identity itself changed, avoid blindly restoring registry into another slot. */
    {
        struct rp_account now;
        if(!identity(ops,uid,&now) && now.slot==slot && !strcmp(now.name,a.name) &&
           (now.id==expected || now.id==id))
            r->restored=restore(ops,saved,path,reg_attempts,file_attempts,preserve_np_profile);
        if(r->restored) {
            if(ops->file_remove(marker)) r->restored=0;
            else if(identity(ops,uid,&r->account)) r->account=a;
        }
        if(!r->restored) fail(r,"recovery-required","Partial changes remain. Keep the backup for manual recovery.");
    }
    goto done;
clean:
    if(ops->file_remove(marker)) fail(r,"recovery-required","Transaction marker cleanup failed; review backup.");
done:
    if(trace_enabled) save_trace(ops,r);
    free(saved);
}

/* One-shot diagnostic report. Values never leave the probe and no mutator from
 * rp_ops is called. Larger string buffers are observation only, not a fallback. */
int rp_registry_diagnostics(const struct rp_ops *ops,rp_registry_probe probe,char *out,size_t cap) {
    uint32_t ids[4],foreground; struct rp_account account;
    if(!probe || ops->users(ids,&foreground) || identity(ops,foreground,&account) || !account.foreground) {
        return snprintf(out,cap,"{\"ok\":false,\"diagnosticOnly\":true,\"code\":\"target-unverified\",\"fields\":[]}");
    }
    size_t used=0;
#define APPEND(...) do { \
    if(used>=cap) return -1; \
    int added=snprintf(out+used,cap-used,__VA_ARGS__); \
    if(added<0 || (size_t)added>=cap-used) return -1; \
    used+=(size_t)added; \
} while(0)
    APPEND("{\"ok\":true,\"diagnosticOnly\":true,\"userId\":%u,\"slot\":%d,\"fields\":[",foreground,account.slot);
    for(size_t i=0;i<NFIELDS;i++) {
        uint32_t key=fields[i].key+(account.slot-1)*65536;
        int rc=probe(key,fields[i].kind,fields[i].size);
        APPEND("%s{\"key\":%u,\"kind\":%u,\"size\":%u,\"returnStatus\":%d,\"returnStatusHex\":\"0x%08x\",\"stringBufferProbes\":[",
               i ? "," : "",key,fields[i].kind,fields[i].size,(int32_t)rc,(uint32_t)rc);
        if(fields[i].kind==RP_STRING) {
            const unsigned sizes[]={65,128,256}; int first=1;
            for(size_t n=0;n<sizeof(sizes)/sizeof(sizes[0]);n++) {
                if(sizes[n]<=fields[i].size) continue;
                int status=probe(key,RP_STRING,sizes[n]);
                APPEND("%s{\"size\":%u,\"returnStatus\":%d,\"returnStatusHex\":\"0x%08x\"}",
                       first ? "" : ",",sizes[n],(int32_t)status,(uint32_t)status); first=0;
            }
        }
        APPEND("],\"alternateTypeProbes\":[");
        if(rc) {
            const unsigned kinds[]={RP_STRING,RP_BINARY};
            const unsigned sizes[]={1,4,8,17,65,256};
            int first=1;
            for(size_t k=0;k<sizeof(kinds)/sizeof(kinds[0]);k++) {
                if(kinds[k]==fields[i].kind) continue;
                for(size_t n=0;n<sizeof(sizes)/sizeof(sizes[0]);n++) {
                    int status=probe(key,kinds[k],sizes[n]);
                    APPEND("%s{\"kind\":%u,\"size\":%u,\"returnStatus\":%d,\"returnStatusHex\":\"0x%08x\"}",
                           first ? "" : ",",kinds[k],sizes[n],(int32_t)status,(uint32_t)status); first=0;
                }
            }
        }
        APPEND("]}");
    }
    struct rp_account after;
    int stable=!identity(ops,foreground,&after) && after.foreground && after.slot==account.slot &&
               after.id==account.id && !strcmp(after.name,account.name);
    APPEND("],\"targetStable\":%s}",stable ? "true" : "false");
#undef APPEND
    return (int)used;
}

/* Independent read-only recovery audit against the exact native snapshot schema.
 * No restoration/mutation routine is called and no values are serialized. */
int rp_restore_diagnostics(const struct rp_ops *ops,char *out,size_t cap) {
    uint32_t ids[4],foreground; struct rp_account account;
    if(ops->users(ids,&foreground) || identity(ops,foreground,&account) || !account.foreground)
        return snprintf(out,cap,"{\"ok\":false,\"diagnosticOnly\":true,\"code\":\"target-unverified\"}");
    struct rp_snapshot *saved=calloc(1,sizeof(*saved));
    if(!saved) return -1;
    char snapshot_path[256],marker[256],path[2][256];
    snprintf(snapshot_path,sizeof(snapshot_path),"%s/%x.snapshot",ops->backup_root,foreground);
    snprintf(marker,sizeof(marker),"%s/%x.state",ops->backup_root,foreground);
    paths(ops,foreground,path);
    size_t size=sizeof(*saved); int snapshot_status=ops->file_read(snapshot_path,(unsigned char *)saved,&size);
    int valid=!snapshot_status && size==sizeof(*saved) && saved->magic==0x52505331 && saved->version==2 &&
              saved->uid==foreground && saved->slot==(uint32_t)account.slot;
    for(size_t i=0;valid && i<NFIELDS;i++) {
        const struct rp_value *v=&saved->registry[i];
        valid=v->key==fields[i].key+(account.slot-1)*65536 && v->kind==fields[i].kind && v->size==fields[i].size &&
              (!saved->unsupported_status[i] || legacy_absent(ops,v->key,saved->unsupported_status[i]));
    }
    for(int i=0;valid && i<2;i++)
        valid=saved->existed[i]<=1 && saved->size[i]<=RP_FILE_MAX && (saved->existed[i] || !saved->size[i]);
    if(!valid) {
        free(saved);
        return snprintf(out,cap,"{\"ok\":false,\"diagnosticOnly\":true,\"code\":\"snapshot-invalid\",\"snapshotReadStatus\":%d}",snapshot_status);
    }
    size_t used=0; int all=account.id==saved->old_id;
#define RESTORE_APPEND(...) do { \
    if(used>=cap) { free(saved); return -1; } \
    int added=snprintf(out+used,cap-used,__VA_ARGS__); \
    if(added<0 || (size_t)added>=cap-used) { free(saved); return -1; } \
    used+=(size_t)added; \
} while(0)
    RESTORE_APPEND("{\"ok\":true,\"diagnosticOnly\":true,\"schemaValidated\":true,\"snapshotVersion\":2,"
        "\"userId\":%u,\"slot\":%d,\"accountIdMatches\":%s,\"registry\":[",foreground,account.slot,all?"true":"false");
    for(size_t i=0;i<NFIELDS;i++) {
        struct rp_value actual=saved->registry[i];
        int status=ops->reg_get(&actual);
        int match=saved->unsupported_status[i]
            ? status==saved->unsupported_status[i] && legacy_absent(ops,actual.key,status)
            : !status && !memcmp(actual.data,saved->registry[i].data,actual.size);
        if(!match) all=0;
        RESTORE_APPEND("%s{\"key\":%u,\"kind\":%u,\"size\":%u,\"supported\":%s,\"readStatus\":%d,\"readStatusHex\":\"0x%08x\",\"matches\":%s}",
            i?",":"",actual.key,actual.kind,actual.size,saved->unsupported_status[i]?"false":"true",
            (int32_t)status,(uint32_t)status,match?"true":"false");
    }
    RESTORE_APPEND("],\"files\":[");
    for(int i=0;i<2;i++) {
        unsigned char bytes[RP_FILE_MAX]; size_t n=sizeof(bytes);
        int status=ops->file_read(path[i],bytes,&n);
        int match=saved->existed[i]
            ? !status && n==saved->size[i] && !memcmp(bytes,saved->files[i],n)
            : status==1;
        if(!match) all=0;
        RESTORE_APPEND("%s{\"file\":\"%s\",\"expectedExists\":%s,\"currentExists\":%s,\"readStatus\":%d,\"matches\":%s}",
            i?",":"",i?"config.dat":"np/auth.dat",saved->existed[i]?"true":"false",status==0?"true":"false",status,match?"true":"false");
    }
    unsigned char state[32]; size=sizeof(state); int marker_status=ops->file_read(marker,state,&size);
    int marker_absent=marker_status==1;
    struct rp_account after;
    int stable=!identity(ops,foreground,&after) && after.foreground && after.slot==account.slot &&
        after.id==account.id && !strcmp(after.name,account.name);
    RESTORE_APPEND("],\"markerAbsent\":%s,\"markerReadStatus\":%d,\"targetStable\":%s,\"restorationVerified\":%s}",
        marker_absent?"true":"false",marker_status,stable?"true":"false",all&&marker_absent&&stable?"true":"false");
#undef RESTORE_APPEND
    free(saved); return (int)used;
}

