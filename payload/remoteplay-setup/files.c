/* SPDX-License-Identifier: GPL-3.0-only */
#include "files.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdint.h>

#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
/* No symlinks, oversized reads, truncate-in-place writes, or unchecked short IO. */
int rp_file_read(const char *path,unsigned char *data,size_t *size) {
    int fd=open(path,O_RDONLY|O_NOFOLLOW);
    if(fd<0) return errno==ENOENT ? 1 : -1;
    struct stat st; int rc=-1;
    if(!fstat(fd,&st) && S_ISREG(st.st_mode) && st.st_size>=0 && (uint64_t)st.st_size<=*size) {
        size_t total=(size_t)st.st_size,done=0;
        while(done<total) {
            ssize_t n=read(fd,data+done,total-done);
            if(n<0 && errno==EINTR) continue;
            if(n<=0) break;
            done+=(size_t)n;
        }
        unsigned char trailing;
        if(done==total && read(fd,&trailing,1)==0) { *size=done; rc=0; }
    }
    if(close(fd)) rc=-1;
    return rc;
}
static int sync_parent(const char *path) {
    char parent[512]; if(strlen(path)>=sizeof(parent)) return -1;
    strcpy(parent,path); char *slash=strrchr(parent,'/'); if(!slash) return -1; *slash=0;
    int fd=open(parent,O_RDONLY|O_DIRECTORY|O_NOFOLLOW); if(fd<0) return -1;
    int rc=fsync(fd); if(close(fd)) rc=-1; return rc;
}
int rp_file_write(const char *path,const unsigned char *data,size_t size) {
    char temp[512]; if(snprintf(temp,sizeof(temp),"%s.rp-stage",path)>=(int)sizeof(temp)) return -1;
    struct stat st;
    mode_t mode=strstr(path,".snapshot")||strstr(path,".state")||strstr(path,".diagnostics.json")||strstr(path,".trace.json")||strstr(path,".restoration.json") ? 0600 : 0644;
    int existed=0;
    if(!lstat(path,&st)) { if(!S_ISREG(st.st_mode)) return -1; mode=st.st_mode&0777; existed=1; }
    else if(errno!=ENOENT) return -1;
    int fd=open(temp,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,mode); if(fd<0) return -1;
    if(existed) {
        struct stat staged;
        if(fstat(fd,&staged) ||
           ((staged.st_uid!=st.st_uid || staged.st_gid!=st.st_gid) && fchown(fd,st.st_uid,st.st_gid))) {
            int close_rc=close(fd), unlink_rc=unlink(temp);
            (void)close_rc; (void)unlink_rc; return -1;
        }
    }
    if(fchmod(fd,mode)) { int rc=close(fd), removed=unlink(temp); (void)rc; (void)removed; return -1; }
    size_t done=0; int rc=-1;
    while(done<size) {
        ssize_t n=write(fd,data+done,size-done);
        if(n<0 && errno==EINTR) continue;
        if(n<=0) break;
        done+=(size_t)n;
    }
    if(done==size && !fsync(fd)) rc=0;
    if(close(fd)) rc=-1;
    if(!rc && rename(temp,path)) rc=-1;
    if(!rc && sync_parent(path)) rc=-1;
    if(rc && unlink(temp) && errno!=ENOENT) return -1;
    return rc;
}
int rp_file_remove(const char *path) {
    if(unlink(path)) return errno==ENOENT ? 0 : -1;
    return sync_parent(path);
}
int rp_mkdir(const char *path,unsigned mode) {
    if(mkdir(path,(mode_t)mode)) {
        if(errno!=EEXIST) return -1;
        struct stat st; return lstat(path,&st)||!S_ISDIR(st.st_mode) ? -1 : 0;
    }
    int fd=open(path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);
    if(fd<0) return -1;
    int rc=fchmod(fd,(mode_t)mode);
    if(!rc && fsync(fd)) rc=-1;
    if(close(fd)) rc=-1;
    return rc ? -1 : sync_parent(path);
}
