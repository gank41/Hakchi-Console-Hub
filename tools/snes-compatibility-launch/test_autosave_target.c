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
int main(void){char path[]="/tmp/hc-target-XXXXXX";assert(mkdtemp(path));int parent=open(path,O_RDONLY|O_DIRECTORY);assert(parent>=0);
 assert(mkdirat(parent,"work",0700)==0);int work=openat(parent,"work",O_RDONLY|O_DIRECTORY);assert(work>=0);
 int old=openat(parent,"state",O_RDWR|O_CREAT|O_EXCL,0600);assert(old>=0 && write(old,"OLD",3)==3);
 int tmp=openat(work,"new",O_RDWR|O_CREAT|O_EXCL,0600);assert(tmp>=0);HCAutosaveTarget target=HC_AUTOSAVE_TARGET_INITIALIZER;
 char identity[1024],other[1024];assert(snprintf(identity,sizeof identity,"%s/state",path)>0 && snprintf(other,sizeof other,"%s/other",path)>0);
 assert(fcntl(parent,F_SETFD,FD_CLOEXEC)==0 && fcntl(work,F_SETFD,FD_CLOEXEC)==0);
 assert(fcntl(tmp,F_SETFD,0)==0 && hc_autosave_target_init(&target,parent,work,tmp,geteuid(),identity,"state","new")<0);
 assert(fcntl(tmp,F_SETFD,FD_CLOEXEC)==0);
 assert(hc_autosave_target_init(&target,parent,work,tmp,geteuid(),"/tmp/state","state","new")<0);
 assert(hc_autosave_target_init(&target,parent,work,tmp,geteuid(),identity,"state","new")==0);
 assert(hc_autosave_target_write(&target,other,"NEW",3)<0);
 char data[4]={0};assert(pread(old,data,3,0)==3 && !strcmp(data,"OLD"));
 assert(hc_autosave_target_write(&target,identity,"NEW",3)==0);
 assert(hc_autosave_target_write(&target,identity,"BAD",3)<0);
 int dest=openat(parent,"state",O_RDONLY);assert(dest>=0 && read(dest,data,3)==3 && !strcmp(data,"NEW"));
 int backup=openat(work,"previous",O_RDONLY);assert(backup>=0 && read(backup,data,3)==3 && !strcmp(data,"OLD"));
 close(backup);close(dest);close(old);close(tmp);close(work);assert(unlinkat(parent,"state",0)==0);
 int d=openat(parent,"work",O_RDONLY|O_DIRECTORY);assert(d>=0 && unlinkat(d,"previous",0)==0);close(d);
 assert(unlinkat(parent,"work",AT_REMOVEDIR)==0);close(parent);assert(rmdir(path)==0);return 0;}
