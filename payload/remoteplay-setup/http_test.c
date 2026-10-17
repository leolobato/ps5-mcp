/* SPDX-License-Identifier: GPL-3.0-only
 * Socket-pair tests: no TCP listeners or console communication. */
#define main rp_model_test_main
#include "host_test.c"
#undef main
#define main rp_server_main
#include "main.c"
#undef main
const struct rp_ops rp_platform={users,name,reg_get,reg_set,rp_file_read,file_write,rp_file_remove,rp_mkdir,
        random_bytes,language,home,backup,legacy_profile_enabled};
int rp_platform_init(char firmware[16]) { strcpy(firmware,"13.60"); return 0; }
int rp_admission_run(enum rp_admission_mode mode, struct rp_admission_result *result) {
    if(writes || file_calls) abort();
    memset(result,0,sizeof *result); result->ok=1;
    snprintf(result->code,sizeof result->code,"%s",mode==RP_ADMISSION_CHECK?"stock":mode==RP_ADMISSION_APPLY?"patched":"restored");
    return 0;
}
int main(int argc,char **argv) {
    if(argc!=3 && argc!=4) return 2;
    if(argc==3 || (strcmp(argv[3],"unconfigured") && strcmp(argv[3],"startup-unconfigured"))) for(int i=0;i<64;i++) rp_auth_token[i]='a';
    rp_expires=rp_now()+(argc==4 && !strcmp(argv[3],"expired") ? -1 : 900);
    if(argc==4 && !strcmp(argv[3],"startup-unconfigured")) {
        if(rp_server_main()!=1) return 2;
        puts("unconfigured startup rejected"); return 0;
    }
    if(argc==4 && !strcmp(argv[3],"used")) rp_attempted=1;
    int fds[2]; if(socketpair(AF_UNIX,SOCK_STREAM,0,fds)) return 2;
    if(send_all(fds[0],argv[1],strlen(argv[1])) || shutdown(fds[0],SHUT_WR)) return 2;
    request(fds[1],argv[2]); close(fds[1]);
    char buf[1024]; ssize_t n;
    while((n=read(fds[0],buf,sizeof(buf)))>0) fwrite(buf,1,(size_t)n,stdout);
    close(fds[0]); fprintf(stderr,"writes=%d,fileWrites=%d,users=%d\n",writes,file_calls,users_calls); return 0;
}
