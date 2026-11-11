#define _POSIX_C_SOURCE 200809L
#include "size-probe-runner.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
/* Checked path equality does not lock directories; caller retains exclusivity. */
static int checked_path(HCVerifiedLaunch *v,const char *path,int executable){
 struct stat a,b;int fd;if(!v||!v->ready||!path||path[0]!='/'||hc_verified_launch_recheck(v)||(executable&&!(v->snapshot.st_mode&S_IXUSR)))return 0;
 fd=open(path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return 0;
 int ok=!fstat(fd,&a)&&!fstat(v->rom_fd,&b)&&S_ISREG(a.st_mode)&&a.st_dev==b.st_dev&&a.st_ino==b.st_ino;
 if(close(fd))return 0;return ok;
}
static int monotonic_ms(unsigned long long *out){
 struct timespec t;if(clock_gettime(CLOCK_MONOTONIC,&t)||t.tv_sec<0)return -1;
 *out=(unsigned long long)t.tv_sec*1000u+(unsigned long long)t.tv_nsec/1000000u;return 0;
}
int hc_size_probe_start(HCSizeProbe *p,HCVerifiedLaunch *program,const char *program_path,HCVerifiedLaunch *core,const char *core_path,HCVerifiedLaunch *rom,const char *scratch){
 int pipes[2]={-1,-1},err;unsigned long long now;struct stat dir;posix_spawn_file_actions_t actions;pid_t child=-1;
 if(!p||p->pid!=-1||p->output!=-1||p->complete||p->failed||!rom||!rom->ready||!scratch||scratch[0]!='/'||lstat(scratch,&dir)||!S_ISDIR(dir.st_mode)||dir.st_uid!=geteuid()||(dir.st_mode&0777)!=0700||
    !checked_path(program,program_path,1)||!checked_path(core,core_path,0)||hc_verified_launch_recheck(rom)){errno=EINVAL;return -1;}
 struct sigaction child_action;
 if(sigaction(SIGCHLD,NULL,&child_action)||child_action.sa_handler==SIG_IGN||(child_action.sa_flags&SA_NOCLDWAIT)){errno=EINVAL;return -1;}
 if(monotonic_ms(&now))return -1;
 errno=0;if(fcntl(210,F_GETFD)!=-1||errno!=EBADF){errno=EBUSY;return -1;}
 if(pipe(pipes))return -1;
 for(int i=0;i<2;i++) {int f=fcntl(pipes[i],F_GETFD);if(pipes[i]<3||pipes[i]==210||f<0||fcntl(pipes[i],F_SETFD,f|FD_CLOEXEC)<0){err=errno;goto fail;}}
 {int f=fcntl(pipes[0],F_GETFL);if(f<0||fcntl(pipes[0],F_SETFL,f|O_NONBLOCK)<0){err=errno;goto fail;}}
 if((err=posix_spawn_file_actions_init(&actions)))goto fail;
 if((err=posix_spawn_file_actions_adddup2(&actions,pipes[1],STDOUT_FILENO))||
    (err=posix_spawn_file_actions_adddup2(&actions,rom->rom_fd,210))||
    (err=posix_spawn_file_actions_addclose(&actions,pipes[0]))||
    (err=posix_spawn_file_actions_addclose(&actions,pipes[1]))){posix_spawn_file_actions_destroy(&actions);goto fail;}
 char *const argv[]={(char *)program_path,(char *)core_path,(char *)"210",(char *)scratch,NULL};
 char *const envp[]={(char *)"PATH=/usr/bin:/bin",NULL};
 err=posix_spawn(&child,program_path,&actions,NULL,argv,envp);posix_spawn_file_actions_destroy(&actions);
 if(err)goto fail;
 close(pipes[1]);p->pid=child;p->output=pipes[0];p->deadline_ms=now+10000u;p->program=program;p->core=core;p->rom=rom;
 /* Failure after spawn retains the child and requires caller cancellation/reap. */
 if(!checked_path(program,program_path,1)||!checked_path(core,core_path,0)||hc_verified_launch_recheck(rom)){p->failed=1;errno=EIO;return -1;}
 return 0;
fail:
 if(pipes[0]>=0)close(pipes[0]);if(pipes[1]>=0)close(pipes[1]);errno=err?err:EIO;return -1;
}
int hc_size_probe_poll(HCSizeProbe *p,size_t *out){
 if(!p||!out||p->pid<=0||p->output<0||p->complete){errno=EINVAL;return -1;}
 unsigned long long now;
 if(monotonic_ms(&now)||now>=p->deadline_ms){p->failed=1;(void)kill(p->pid,SIGKILL);}
 for(;;){char buf[32];ssize_t n=read(p->output,buf,sizeof buf);if(n>0){if((size_t)n>sizeof p->bytes-p->used){p->failed=1;break;}memcpy(p->bytes+p->used,buf,(size_t)n);p->used+=(size_t)n;continue;}
  if(n<0&&errno==EINTR)continue;if(n<0&&errno!=EAGAIN&&errno!=EWOULDBLOCK)p->failed=1;break;}
 int status;pid_t r=waitpid(p->pid,&status,WNOHANG);if(!r)return 0;if(r<0){if(errno==EINTR)return 0;p->failed=1;
  /* ECHILD means no owned process remains to reap. Never trust its output. */
  if(errno==ECHILD){int saved=errno;(void)close(p->output);p->output=-1;p->pid=-1;p->complete=1;errno=saved;}
  return -1;}
 /* Drain once more after reaping. EAGAIN means a descendant still owns the
  * writer, so no size is trusted even if a complete line was observed. */
 for(;;){char buf[32];ssize_t n=read(p->output,buf,sizeof buf);if(n>0){if((size_t)n>sizeof p->bytes-p->used){p->failed=1;break;}memcpy(p->bytes+p->used,buf,(size_t)n);p->used+=(size_t)n;continue;}if(n<0&&errno==EINTR)continue;if(n!=0)p->failed=1;break;}
 if(close(p->output))p->failed=1;p->output=-1;p->pid=-1;p->complete=1;
 int identities_ok=!hc_verified_launch_recheck(p->program)&&!hc_verified_launch_recheck(p->core)&&!hc_verified_launch_recheck(p->rom);
 if(identities_ok&&!p->failed&&WIFEXITED(status)&&WEXITSTATUS(status)==3&&!p->used){p->reason=HC_SIZE_PROBE_CLOCK_REQUIRED;errno=ENOTSUP;return -1;}
 if(!identities_ok||!WIFEXITED(status)||WEXITSTATUS(status)||p->failed||!p->used||p->bytes[p->used-1]!='\n'||p->used>9){errno=EIO;return -1;}
 size_t value=0;for(size_t i=0;i+1<p->used;i++){unsigned char c=(unsigned char)p->bytes[i];if(c<'0'||c>'9'||(i==0&&p->used>2&&c=='0')){errno=EIO;return -1;}value=value*10+(c-'0');}
 if(p->used==1||value>4u*1024u*1024u){errno=EIO;return -1;}p->size=value;p->verified=1;*out=value;return 1;
}
int hc_size_probe_cancel(HCSizeProbe *p){if(!p||p->pid<=0||p->complete){errno=EINVAL;return -1;}p->failed=1;return kill(p->pid,SIGKILL);}
