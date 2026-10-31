#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#include "child_process.h"
#include "control_pipe.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
/* Added API under test; input remains caller-owned. */
extern int hc_child_start_verified(HCChild *,const char *,char *const [],char *const [],int,int,int,int,int,int,int,int,int,int,int,int);
int main(int argc,char **argv){
 if(argc==2&&!strcmp(argv[1],"child")){char b[3];if(pread(205,b,3,0)!=3||memcmp(b,"ROM",3))return 1;errno=0;return pwrite(205,"X",1,0)<0&&errno==EBADF?0:1;}
 struct sigaction ign={0};ign.sa_handler=SIG_IGN;sigemptyset(&ign.sa_mask);assert(!sigaction(SIGPIPE,&ign,NULL));
 int report[2],startup[2],exitpipe[2];assert(!hc_control_pipe(report)&&!hc_control_pipe(startup)&&!hc_control_pipe(exitpipe));char savepath[]="/tmp/hc-save-XXXXXX",imgpath[]="/tmp/hc-image-XXXXXX",rompath[]="/tmp/hc-rom-XXXXXX";int save=mkstemp(savepath),image=mkstemp(imgpath),rw=mkstemp(rompath);assert(save>=0&&image>=0&&rw>=0&&write(rw,"ROM",3)==3);int rom=open(rompath,O_RDONLY|O_CLOEXEC|O_NOFOLLOW);assert(rom>=0);assert(!fcntl(save,F_SETFD,FD_CLOEXEC)&&!fcntl(image,F_SETFD,FD_CLOEXEC)&&!fcntl(rw,F_SETFD,FD_CLOEXEC));
 HCChild c=HC_CHILD_INITIALIZER;char *args[]={argv[0],"child",NULL},*env[]={NULL};
 assert(hc_child_start_verified(&c,argv[0],args,env,report[1],200,save,201,image,202,startup[1],203,exitpipe[1],204,rw,205)<0&&c.pid==-1);
 assert(hc_child_start_verified(&c,argv[0],args,env,report[1],200,save,201,image,202,startup[1],203,exitpipe[1],204,rom,203)<0&&c.pid==-1);
 assert(!hc_child_start_verified(&c,argv[0],args,env,report[1],200,save,201,image,202,startup[1],203,exitpipe[1],204,rom,205));
 int status=0,result=0;struct timespec delay={0,1000000};for(int i=0;i<5000&&!result;i++){result=hc_child_poll(&c,&status);if(!result)nanosleep(&delay,NULL);}assert(result==1&&WIFEXITED(status)&&WEXITSTATUS(status)==0);assert(fcntl(rom,F_GETFD)>=0);
 close(report[0]);close(report[1]);close(startup[0]);close(startup[1]);close(exitpipe[0]);close(exitpipe[1]);close(rom);close(rw);close(save);close(image);assert(!unlink(rompath)&&!unlink(savepath)&&!unlink(imgpath));return 0;
}
