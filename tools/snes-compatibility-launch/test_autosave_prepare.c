#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#include "autosave_target.h"
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
int main(void){char dir[]="/tmp/hc-prepare-XXXXXX";assert(mkdtemp(dir));int parent=open(dir,O_RDONLY|O_DIRECTORY|O_CLOEXEC);assert(parent>=0);
 int old=openat(parent,"state",O_RDWR|O_CREAT|O_EXCL,0600);assert(old>=0&&write(old,"OLD",3)==3);
 char path[1024];assert(snprintf(path,sizeof path,"%s/state",dir)>0);uint8_t nonce[16]={5};HCAutosaveTarget t=HC_AUTOSAVE_TARGET_INITIALIZER;
 assert(hc_autosave_target_prepare(&t,parent,geteuid(),nonce,path,"state")==0);
 assert(hc_autosave_target_acquire(&t)==0);assert(hc_autosave_target_close(&t)<0);assert(hc_autosave_target_acquire(&t)<0);
 assert(hc_autosave_target_release(&t)==0);
 HCAutosaveTarget duplicate=HC_AUTOSAVE_TARGET_INITIALIZER;assert(hc_autosave_target_prepare(&duplicate,parent,geteuid(),nonce,path,"state")<0);
 assert(hc_autosave_target_write(&t,path,"NEW",3)==0);int current=openat(parent,"state",O_RDONLY);assert(current>=0);char b[4]={0};assert(read(current,b,3)==3&&!strcmp(b,"NEW"));
 int previous=openat(t.workspace,"previous",O_RDONLY);assert(previous>=0&&read(previous,b,3)==3&&!strcmp(b,"OLD"));close(previous);close(current);close(old);
 char workspace[44];memcpy(workspace,t.workspace_name,sizeof workspace);int work=dup(t.workspace);assert(work>=0);assert(hc_autosave_target_close(&t)==0);
 assert(unlinkat(work,"previous",0)==0);close(work);assert(unlinkat(parent,workspace,AT_REMOVEDIR)==0);assert(unlinkat(parent,"state",0)==0);close(parent);assert(rmdir(dir)==0);return 0;}
