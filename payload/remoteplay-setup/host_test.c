/* SPDX-License-Identifier: GPL-3.0-only
 * Local recording backend. No console address or console calls. */
#include "setup.h"
#include "files.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
static struct rp_value values[128];
static int nvalues,writes,other_writes,id_writes,users_calls,fail_reg,fail_file,fail_backup;
static int file_calls,fail_read,probe_calls,legacy_missing,legacy_wrong_error,legacy_writes,disable_profile,legacy_reads,legacy_appears,legacy_disappears,legacy_written;
static int foreground_after=1,profile_flips;
static unsigned char initial_ext[65];
static int ext_writes,ext_reads,ext_drift_at_read,ext_drift_write,ext_padding_drift;
static const uint32_t np_bases[]={125830912,125831936,125832704,125882625,125854723,125833216};
static const unsigned np_offsets[]={0xa4,0xb4,0xd0,0xd4,0xdc,0xf4};
static uint32_t np_initial[]={0xfffffbff,0x12345678,0x89abcdef,0x76543210,0xfedcba98,0xaabbccdd};
static int np_setters[6],np_reads[6],np_target=-1,np_drift_read,np_drift_write;
static uint32_t initial_a4=0xfffffbff;
static int a4_writes,a4_reads,a4_drift_at_read,a4_drift_on_write;
static int postread_mode,postread_seen,fail_trace;
static int recovery_failure,change_foreground,ambiguous,slot=3,file_failure_seen;
static uint64_t initial_id;
static char home[256],backup[256];
static const uint32_t uid=0x10000001;
static int users(uint32_t ids[4],uint32_t *fg) {
    memset(ids,0,16); ids[0]=uid; *fg=uid;
    users_calls++;
    if(change_foreground && users_calls>foreground_after) *fg=uid+1;
    return 0;
}
static int name(uint32_t id,char out[33]) { if(id!=uid) return -1; strcpy(out,"Offline"); return 0; }
static int reg_get(struct rp_value *v) {
    memset(v->data,0,sizeof(v->data));
    if(v->key==125874195+(unsigned)(slot-1)*65536) {
        ext_reads++;
        if(ext_drift_at_read && ext_reads>=ext_drift_at_read) initial_ext[ext_padding_drift?64:0]=0x7f;
    }
    for(int k=0;k<6;k++) if(v->key==np_bases[k]+(unsigned)(slot-1)*65536) {
        np_reads[k]++;
        if(np_target==k && np_drift_read && np_reads[k]>=np_drift_read) {
            np_initial[k]=0x11223344;
            if(k==0) initial_a4=0x11223344;
        }
    }
    if(v->key==125830912+(unsigned)(slot-1)*65536) {
        a4_reads++;
        if(a4_drift_at_read && a4_reads>=a4_drift_at_read) initial_a4=0x11223344;
    }
    if((legacy_missing || legacy_disappears) && v->key==125830144+(unsigned)(slot-1)*65536) {
        legacy_reads++;
        if((legacy_missing && (!legacy_appears || legacy_reads<legacy_appears)) || (legacy_disappears && legacy_reads>=5))
            return (int32_t)(legacy_wrong_error ? 0x800d0207 : 0x800d0203);
    }
    if(fail_read && v->key==125830656+(unsigned)(slot-1)*65536) return (int32_t)(fail_read==2 ? 0x800d0203 : 0x80550003);
    for(int s=1;s<=16;s++) if(v->key==125829632+(unsigned)(s-1)*65536) {
        if(s==slot || (ambiguous && s==slot+1)) strcpy((char *)v->data,"Offline");
        return 0;
    }
    for(int i=0;i<nvalues;i++) if(values[i].key==v->key) {
        memcpy(v->data,values[i].data,v->size);
        if(postread_mode && !postread_seen && v->key==125830656+(unsigned)(slot-1)*65536) {
            postread_seen=1;
            if(postread_mode==1) return (int32_t)0x800d0208;
            if(postread_mode==2) v->data[0]=0;
            if(postread_mode==3) {
                size_t length=strlen((char *)v->data); if(length+1<v->size) v->data[length+1]=0x7f;
            }
        }
        return 0;
    }
    if(v->key==125874195+(unsigned)(slot-1)*65536) memcpy(v->data,initial_ext,65);
    if(v->key==125830400+(unsigned)(slot-1)*65536) memcpy(v->data,&initial_id,8);
    for(int k=0;k<6;k++) if(v->key==np_bases[k]+(unsigned)(slot-1)*65536) memcpy(v->data,&np_initial[k],4);
    if(v->key==125830912+(unsigned)(slot-1)*65536) memcpy(v->data,&initial_a4,4);
    return 0;
}
static int reg_set(const struct rp_value *v) {
    writes++;
    if(v->key==125874195+(unsigned)(slot-1)*65536) ext_writes++;
    if(ext_drift_write && writes>=ext_drift_write) initial_ext[ext_padding_drift?64:0]=0x7f;
    for(int k=0;k<6;k++) if(v->key==np_bases[k]+(unsigned)(slot-1)*65536) np_setters[k]++;
    if(np_target>=0 && np_drift_write && writes>=np_drift_write) {
        np_initial[np_target]=0x11223344;
        if(np_target==0) initial_a4=0x11223344;
    }
    if(v->key==125830912+(unsigned)(slot-1)*65536) a4_writes++;
    if(a4_drift_on_write && writes>=a4_drift_on_write) initial_a4=0x11223344;
    if(profile_flips && writes>=3) disable_profile=1;
    if(v->key==125830144+(unsigned)(slot-1)*65536) {
        legacy_writes++;
        if(legacy_disappears && legacy_written) return (int32_t)0x800d0203;
        legacy_written=1;
    }
    if(v->key<125829632+(unsigned)(slot-1)*65536 || v->key>=125829632+(unsigned)slot*65536) other_writes++;
    if(v->key==125830400+(unsigned)(slot-1)*65536) id_writes++;
    if(fail_reg && (writes==fail_reg || (recovery_failure && writes>=fail_reg))) return -1;
    for(int i=0;i<nvalues;i++) if(values[i].key==v->key) { values[i]=*v; return 0; }
    values[nvalues++]=*v; return 0;
}
static int file_write(const char *path,const unsigned char *data,size_t size) {
    file_calls++;
    if(fail_trace && strstr(path,".trace.json")) return -1;
    if(fail_backup && strstr(path,".snapshot")) return -1;
    if(fail_file && strstr(path,"config.dat") && !file_failure_seen++) return -1;
    return rp_file_write(path,data,size);
}
static int random_bytes(void *data,size_t size) { memset(data,0x42,size); return 0; }
static int language(int *n) { *n=1; return 0; }
static int legacy_profile_enabled(void) { return !disable_profile; }
static int diagnostic_probe(uint32_t key,unsigned kind,unsigned size) {
    probe_calls++;
    if(key==125830656+(unsigned)(slot-1)*65536) return (int32_t)0x80550003;
    if(key==125874190+(unsigned)(slot-1)*65536 && kind==RP_STRING && size<65)
        return (int32_t)0x80550004;
    return 0;
}
int main(int argc,char **argv) {
    if(argc<2) return 2;
    for(unsigned i=0;i<65;i++) initial_ext[i]=(unsigned char)(i^0x5a);
    memcpy(initial_ext,"saved opaque",12); initial_ext[12]=0;
    char root[]="/tmp/remoteplay-setup-XXXXXX"; if(!mkdtemp(root)) return 2;
    snprintf(home,sizeof(home),"%s/home",root); snprintf(backup,sizeof(backup),"%s/backup",root);
    if(rp_mkdir(home,0700)) return 2;
    char user_dir[512]; snprintf(user_dir,sizeof(user_dir),"%s/%x",home,uid); if(rp_mkdir(user_dir,0700)) return 2;
    if(!strcmp(argv[1],"existing") || !strcmp(argv[1],"existing-error")) initial_id=0x8877665544332211ULL;
    if(!strcmp(argv[1],"existing-error")) fail_reg=15;
    if(!strncmp(argv[1],"registry-error-",15)) fail_reg=atoi(argv[1]+15);
    if(!strcmp(argv[1],"ambiguous") || !strcmp(argv[1],"diagnostic-ambiguous")) ambiguous=1;
    if(!strcmp(argv[1],"read-error")) fail_read=1;
    if(!strncmp(argv[1],"ext-case-",9)) {
        ext_padding_drift=strstr(argv[1],"padding")!=NULL;
        if(strstr(argv[1],"before")) ext_drift_at_read=2;
        if(strstr(argv[1],"during")) ext_drift_write=3;
        if(strstr(argv[1],"late-failure")) { ext_drift_write=15; fail_reg=15; }
        if(strstr(argv[1],"final")) ext_drift_at_read=4;
    }
    if(!strncmp(argv[1],"np-case-",8)) {
        np_target=atoi(argv[1]+8);
        if(np_target<0 || np_target>=6) return 2;
        if(strstr(argv[1],"-before")) np_drift_read=2;
        if(strstr(argv[1],"-during")) np_drift_write=3;
        if(strstr(argv[1],"-late-failure")) { np_drift_write=15; fail_reg=15; }
        if(strstr(argv[1],"-final")) np_drift_read=4;
    }
    if(!strcmp(argv[1],"a4-full-preserve")) initial_a4=0xa1b2c3d4;
    if(!strcmp(argv[1],"a4-drift-before")) a4_drift_at_read=2;
    if(!strcmp(argv[1],"a4-drift-during")) a4_drift_on_write=3;
    if(!strcmp(argv[1],"a4-drift-final")) a4_drift_at_read=4;
    if(!strcmp(argv[1],"a4-profile-flip")) { profile_flips=1; a4_drift_on_write=3; }
    if(!strcmp(argv[1],"a4-drift-late-failure")) { a4_drift_on_write=15; fail_reg=15; }
    if(!strcmp(argv[1],"registry-readback-error")) postread_mode=1;
    if(!strcmp(argv[1],"registry-value-difference")) postread_mode=2;
    if(!strcmp(argv[1],"registry-padding-difference")) postread_mode=3;
    if(!strcmp(argv[1],"trace-error")) { fail_reg=3; fail_trace=1; }
    if(!strcmp(argv[1],"other-key-invalid")) fail_read=2;
    if(!strncmp(argv[1],"legacy-",7)) legacy_missing=1;
    if(!strcmp(argv[1],"legacy-wrong-error")) legacy_wrong_error=1;
    if(!strcmp(argv[1],"legacy-appears")) legacy_appears=2;
    if(!strcmp(argv[1],"legacy-appears-final")) legacy_appears=3;
    if(!strcmp(argv[1],"legacy-disappears-final")) { legacy_missing=0; legacy_disappears=1; }
    if(!strcmp(argv[1],"legacy-wrong-profile")) disable_profile=1;
    if(!strcmp(argv[1],"legacy-rollback")) fail_reg=10;
    if(!strcmp(argv[1],"changed")) change_foreground=1;
    if(!strcmp(argv[1],"file-error")) fail_file=1;
    if(!strcmp(argv[1],"registry-error")) fail_reg=3;
    if(!strcmp(argv[1],"backup-error")) fail_backup=1;
    if(!strcmp(argv[1],"recovery-error")) { fail_reg=3; recovery_failure=1; }
    if(!strncmp(argv[1],"restore-check",13)) fail_reg=3;
    if(!strncmp(argv[1],"restore-check-legacy",20)) legacy_missing=1;
    if(strstr(argv[1],"existing-files")) {
        char np[512],file[512]; snprintf(np,sizeof(np),"%s/%x/np",home,uid);
        if(rp_mkdir(np,0755)) return 2;
        snprintf(file,sizeof(file),"%s/%x/np/auth.dat",home,uid);
        if(rp_file_write(file,(const unsigned char *)"auth",4)) return 2;
        snprintf(file,sizeof(file),"%s/%x/config.dat",home,uid);
        if(rp_file_write(file,(const unsigned char *)"cfg",3)) return 2;
    }
    struct rp_ops ops={users,name,reg_get,reg_set,rp_file_read,file_write,rp_file_remove,rp_mkdir,
        random_bytes,language,home,backup,legacy_profile_enabled};
    if(!strncmp(argv[1],"diagnostic",10)) {
        char report[16384];
        int n=rp_registry_diagnostics(&ops,diagnostic_probe,report,sizeof(report)); if(n<0) return 2;
        puts(report);
        printf("{\"writes\":%d,\"fileWrites\":%d,\"probes\":%d}\n",writes,file_calls,probe_calls);
        printf("%s\n",root); return 0;
    }
    struct rp_result result; rp_prepare(&ops,uid,slot,initial_id,&result);
    char json[4096]; rp_result_json(&result,json,sizeof(json)); puts(json);
    if(!strncmp(argv[1],"restore-check",13)) {
        if(!result.restored) return 4;
        if(!strcmp(argv[1],"restore-check-registry")) {
            struct rp_value changed={.key=125830656+(unsigned)(slot-1)*65536,.kind=RP_STRING,.size=65,.data={'x'}};
            reg_set(&changed);
        }
        if(!strcmp(argv[1],"restore-check-id")) initial_id=0x1122334455667788ULL;
        if(!strcmp(argv[1],"restore-check-file") || !strcmp(argv[1],"restore-check-existing-files-content")) {
            char file[512]; snprintf(file,sizeof(file),"%s/%x/config.dat",home,uid);
            if(rp_file_write(file,(const unsigned char *)"bad",3)) return 2;
        }
        if(!strcmp(argv[1],"restore-check-existing-files-missing")) {
            char file[512]; snprintf(file,sizeof(file),"%s/%x/config.dat",home,uid);
            if(rp_file_remove(file)) return 2;
        }
        if(!strcmp(argv[1],"restore-check-marker")) {
            char marker[512]; snprintf(marker,sizeof(marker),"%s/%x.state",backup,uid);
            if(rp_file_write(marker,(const unsigned char *)"pending",7)) return 2;
        }
        if(!strcmp(argv[1],"restore-check-legacy-changed")) legacy_wrong_error=1;
        if(!strcmp(argv[1],"restore-check-target-changed")) {
            change_foreground=1; users_calls=0; foreground_after=2;
        }
        if(strstr(argv[1],"snapshot-")) {
            if(!strcmp(argv[1],"restore-check-snapshot-short")) {
                if(truncate(result.backup,64)) return 2;
            } else {
                FILE *snapshot=fopen(result.backup,"r+b"); if(!snapshot) return 2;
                long offset=!strcmp(argv[1],"restore-check-snapshot-version") ? 4 :
                            !strcmp(argv[1],"restore-check-snapshot-uid") ? 8 :
                            !strcmp(argv[1],"restore-check-snapshot-slot") ? 12 : 40;
                uint32_t invalid=0xffffffff;
                if(fseek(snapshot,offset,SEEK_SET) || fwrite(&invalid,4,1,snapshot)!=1 || fclose(snapshot)) return 2;
            }
        }
        int prior_writes=writes,prior_files=file_calls;
        char audit[16384]; if(rp_restore_diagnostics(&ops,audit,sizeof(audit))<0) return 2;
        puts(audit);
        printf("{\"auditWrites\":%d,\"auditFileWrites\":%d}\n",writes-prior_writes,file_calls-prior_files);
        printf("%s\n",root); return 0;
    }
    if(!strcmp(argv[1],"a4-full-preserve") || !strcmp(argv[1],"a4-reopen-drift")) {
        char file[512]; snprintf(file,sizeof(file),"%s/%x/config.dat",home,uid);
        unsigned char cfg[RP_FILE_MAX]; size_t n=sizeof(cfg);
        if(rp_file_read(file,cfg,&n) || n<0xa8) return 2;
        uint32_t cfg_a4; memcpy(&cfg_a4,cfg+0xa4,4);
        if(!strcmp(argv[1],"a4-reopen-drift")) initial_a4^=0x02000400;
        struct rp_account current[4]; int count;
        if(rp_inspect(&ops,current,&count) || count!=1) return 2;
        printf("{\"cfgA4\":%u,\"registryA4\":%u,\"verifiedAfterReopen\":%s}\n",cfg_a4,initial_a4,current[0].verified?"true":"false");
    }
    if(!strncmp(argv[1],"np-case-",8)) {
        char file[512]; snprintf(file,sizeof(file),"%s/%x/config.dat",home,uid);
        unsigned char cfg[RP_FILE_MAX]; size_t n=sizeof(cfg); int cfg_matches=0;
        if(!rp_file_read(file,cfg,&n) && n>0xf8) {
            cfg_matches=1;
            for(int k=0;k<6;k++) {
                uint32_t expected=k==0 ? initial_a4 : np_initial[k];
                if(memcmp(cfg+np_offsets[k],&expected,4)) cfg_matches=0;
            }
        }
        if(strstr(argv[1],"-reopen")) {
            np_initial[np_target]^=0x10204080;
            if(np_target==0) initial_a4=np_initial[0];
        }
        struct rp_account current[4]; int count;
        int inspected=!rp_inspect(&ops,current,&count) && count==1;
        int total=0; for(int k=0;k<6;k++) total+=np_setters[k];
        printf("{\"npSetters\":%d,\"targetSetters\":%d,\"allConfigBytesPreserved\":%s,\"reopenVerified\":%s}\n",
            total,np_setters[np_target],cfg_matches?"true":"false",inspected&&current[0].verified?"true":"false");
    }
    if(!strncmp(argv[1],"ext-case-",9)) {
        char file[512]; snprintf(file,sizeof(file),"%s/%x/config.dat",home,uid);
        unsigned char cfg[RP_FILE_MAX]; size_t n=sizeof(cfg);
        int preserved=!rp_file_read(file,cfg,&n) && n>=0x114c+65 && !memcmp(cfg+0x114c,initial_ext,65);
        if(strstr(argv[1],"reopen")) initial_ext[ext_padding_drift?64:0]^=0x40;
        struct rp_account current[4]; int count;
        int inspected=!rp_inspect(&ops,current,&count) && count==1;
        int earlier_ext_writes=0;
        for(int i=0;i<nvalues;i++) if(values[i].key==125874189+(unsigned)(slot-1)*65536 ||
            values[i].key==125874193+(unsigned)(slot-1)*65536) earlier_ext_writes++;
        printf("{\"extSetters\":%d,\"all65BytesPreserved\":%s,\"reopenVerified\":%s,\"otherExtensionsWritten\":%d}\n",
            ext_writes,preserved?"true":"false",inspected&&current[0].verified?"true":"false",earlier_ext_writes);
    }
    int before=writes;
    if(!strcmp(argv[1],"retry") || !strcmp(argv[1],"existing") || !strcmp(argv[1],"legacy-missing")) {
        uint64_t expected=result.account.id; rp_prepare(&ops,uid,slot,expected,&result);
        rp_result_json(&result,json,sizeof(json)); puts(json);
    }
    if(!strcmp(argv[1],"recovery-error")) {
        fail_reg=0; recovery_failure=0;
        rp_prepare(&ops,uid,slot,initial_id,&result); rp_result_json(&result,json,sizeof(json)); puts(json);
    }
    struct rp_value current={.key=125830400+(unsigned)(slot-1)*65536,.kind=RP_BINARY,.size=8};
    reg_get(&current); uint64_t id; memcpy(&id,current.data,8);
    printf("{\"a4Writes\":%d,\"legacyWrites\":%d,\"fileWrites\":%d,\"writes\":%d,\"otherSlotWrites\":%d,\"idWrites\":%d,\"retryWrites\":%d,\"id\":\"0x%016llx\"}\n",
        a4_writes,legacy_writes,file_calls,writes,other_writes,id_writes,writes-before,(unsigned long long)id);
    /* Test runner owns cleanup of the isolated directory. */
    char np_dir[512]; struct stat np_stat,backup_stat;
    snprintf(np_dir,sizeof(np_dir),"%s/%x/np",home,uid);
    if(!stat(np_dir,&np_stat) && !stat(backup,&backup_stat))
        if((np_stat.st_mode&0777)!=0755 || (backup_stat.st_mode&0777)!=0700) return 3;
    printf("%s\n",root);
    return 0;
}
