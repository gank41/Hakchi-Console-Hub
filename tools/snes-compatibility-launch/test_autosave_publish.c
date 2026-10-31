#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#include "autosave_publish.h"
#include <assert.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
int main(void){char p[]="/tmp/hc-publish-XXXXXX";assert(mkdtemp(p));int parent=open(p,O_RDONLY|O_DIRECTORY);assert(parent>=0);
 assert(mkdirat(parent,"work",0700)==0);int work=openat(parent,"work",O_RDONLY|O_DIRECTORY);assert(work>=0);
 int old=openat(parent,"state",O_RDWR|O_CREAT|O_EXCL,0600);assert(old>=0 && write(old,"OLD",3)==3);
 int fresh=openat(work,"new",O_RDWR|O_CREAT|O_EXCL,0600);assert(fresh>=0 && write(fresh,"NEW",3)==3);
 assert(hc_autosave_publish(parent,"state",parent,"state",old,geteuid(),"OLD",3)<0);
 assert(linkat(parent,"state",parent,"other",0)==0);
 assert(hc_autosave_publish(parent,"state",work,"new",fresh,geteuid(),"NEW",3)<0);
 assert(unlinkat(parent,"other",0)==0);
 assert(symlinkat("state",parent,"link")==0);
 assert(hc_autosave_publish(parent,"link",work,"new",fresh,geteuid(),"NEW",3)<0);
 assert(unlinkat(parent,"link",0)==0);
 assert(hc_autosave_publish(parent,"state",work,"new",fresh,geteuid(),"BAD",3)<0);
 char data[4]={0};assert(pread(old,data,3,0)==3 && !strcmp(data,"OLD"));
 assert(hc_autosave_publish(parent,"state",work,"new",fresh,geteuid(),"NEW",3)==0);
 int now=openat(parent,"state",O_RDONLY);assert(now>=0 && read(now,data,3)==3 && !strcmp(data,"NEW"));
 int backup=openat(work,"previous",O_RDONLY);assert(backup>=0 && read(backup,data,3)==3 && !strcmp(data,"OLD"));
 close(backup);close(now);close(old);close(fresh);assert(unlinkat(work,"previous",0)==0 && unlinkat(parent,"state",0)==0);
 int first=openat(work,"first",O_RDWR|O_CREAT|O_EXCL,0600);assert(first>=0 && write(first,"ONE",3)==3);
 assert(hc_autosave_publish(parent,"initial",work,"first",first,geteuid(),"ONE",3)==0);
 int initial=openat(parent,"initial",O_RDONLY);assert(initial>=0 && read(initial,data,3)==3 && !strcmp(data,"ONE"));
 assert(faccessat(work,"previous",F_OK,0)<0);close(initial);close(first);assert(unlinkat(parent,"initial",0)==0);
 close(work);assert(unlinkat(parent,"work",AT_REMOVEDIR)==0);close(parent);assert(rmdir(p)==0);return 0;}
