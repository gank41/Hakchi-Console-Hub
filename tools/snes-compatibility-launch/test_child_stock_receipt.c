#define _GNU_SOURCE 1
#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#include "child_process.h"
#include "control_pipe.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
extern char **environ;

int main(int argc,char **argv){
 if(argc==2&&!strcmp(argv[1],"--child")){
  char rom[3];struct stat dir;
  return read(210,rom,3)!=3||memcmp(rom,"ROM",3)||fstat(212,&dir)||!S_ISDIR(dir.st_mode)||write(211,"S",1)!=1||write(213,"I",1)!=1;
 }
 char name[]="/tmp/hc-child-receipt-XXXXXX";assert(mkdtemp(name));
 int dir=open(name,O_RDONLY|O_DIRECTORY|O_CLOEXEC);assert(dir>=3);
 int rw=openat(dir,"game.sfc",O_CREAT|O_EXCL|O_WRONLY|O_CLOEXEC,0600);assert(rw>=3&&write(rw,"ROM",3)==3&&!close(rw));
 int rom=openat(dir,"game.sfc",O_RDONLY|O_CLOEXEC);assert(rom>=3);
 int report[2],image[2];assert(!hc_control_pipe(report)&&!hc_control_pipe(image));
 HCChild child=HC_CHILD_INITIALIZER;char *args[]={argv[0],"--child",NULL};
 int alias=dup(report[1]);assert(alias>=3&&!fcntl(alias,F_SETFD,FD_CLOEXEC));
 assert(hc_child_start_rom_reporting_lock_receipt(&child,argv[0],args,environ,rom,210,report[1],211,dir,212,alias,213)<0&&child.pid==-1);
 assert(!close(alias));
 assert(hc_child_start_rom_reporting_lock_receipt(&child,argv[0],args,environ,rom,210,report[1],211,dir,212,image[1],211)<0&&child.pid==-1);
 errno=0;assert(fcntl(213,F_GETFD)==-1&&errno==EBADF);int occupied=dup2(dir,213);assert(occupied==213);
 assert(hc_child_start_rom_reporting_lock_receipt(&child,argv[0],args,environ,rom,210,report[1],211,dir,212,image[1],213)<0&&child.pid==-1);
 assert(!close(occupied));
 assert(!hc_child_start_rom_reporting_lock_receipt(&child,argv[0],args,environ,rom,210,report[1],211,dir,212,image[1],213));
 assert(!close(report[1])&&!close(image[1]));int status=0,result=0;struct timespec wait={0,1000000};
 for(int i=0;i<5000&&!result;i++){result=hc_child_poll(&child,&status);if(!result)nanosleep(&wait,NULL);}
 assert(result==1&&WIFEXITED(status)&&WEXITSTATUS(status)==0);char x=0;
 assert(read(report[0],&x,1)==1&&x=='S');assert(read(image[0],&x,1)==1&&x=='I');
 assert(!close(report[0])&&!close(image[0])&&!close(rom));assert(!unlinkat(dir,"game.sfc",0)&&!close(dir)&&!rmdir(name));
 return 0;
}
