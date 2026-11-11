#define _POSIX_C_SOURCE 200809L
#include "startup-monitor-experimental.h"
#include "startup-status.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int child_live(pid_t child) {
 siginfo_t info;
 do { memset(&info,0,sizeof info); if(waitid(P_PID,(id_t)child,&info,WEXITED|WNOHANG|WNOWAIT)==0) {
   if(info.si_pid==0)return 1;
   errno=ECHILD;return 0;
 } } while(errno==EINTR);
 return -1;
}
static int time_left(const struct timespec *start,unsigned timeout_ms) {
 struct timespec now;
 if(clock_gettime(CLOCK_MONOTONIC,&now))return -1;
 /* Relative difference avoids overflow from constructing an absolute deadline. */
 if(now.tv_sec<start->tv_sec || (now.tv_sec==start->tv_sec && now.tv_nsec<start->tv_nsec)){errno=EIO;return -1;}
 time_t sec=now.tv_sec-start->tv_sec; long ns=now.tv_nsec-start->tv_nsec;
 if(ns<0){sec--;ns+=1000000000L;}
 if((uint64_t)sec>(uint64_t)timeout_ms/1000u){errno=ETIMEDOUT;return -1;}
 uint64_t elapsed=(uint64_t)sec*1000u+(uint64_t)ns/1000000u;
 if(elapsed>=timeout_ms){errno=ETIMEDOUT;return -1;}
 unsigned remain=timeout_ms-(unsigned)elapsed;
 return remain>50u?50:(int)remain;
}
int hc_monitor_startup_result(int fd,pid_t child,const uint8_t session[16],uint64_t epoch,unsigned timeout_ms,int *out) {
 struct stat st;struct timespec start; HCStartupReader reader=HC_STARTUP_READER_INIT;
 if(fd<3||child<=0||!out||!timeout_ms){errno=EINVAL;return -1;}
 int flags=fcntl(fd,F_GETFL), fdflags=fcntl(fd,F_GETFD);
 if(flags<0||fdflags<0||(flags&O_ACCMODE)!=O_RDONLY||!(flags&O_NONBLOCK)||!(fdflags&FD_CLOEXEC)||fstat(fd,&st)||!S_ISFIFO(st.st_mode)){errno=EINVAL;return -1;}
 if(hc_startup_reader_init(&reader,session,epoch)||clock_gettime(CLOCK_MONOTONIC,&start))return -1;
 for(;;) {
  int wait=time_left(&start,timeout_ms);if(wait<0)return -1;
  if(child_live(child)!=1)return -1;
  unsigned char buf[256];ssize_t n=read(fd,buf,sizeof buf);
  if(n>0){
   /* Reader errors here describe bytes received from the peer, not caller
    * argument errors; classify malformed, extra and duplicate frames alike. */
   if(hc_startup_feed(&reader,buf,(size_t)n)){errno=EPROTO;return -1;}continue;
  }
  if(n==0){int status=hc_startup_eof(&reader);if(status!=HC_STARTUP_OK&&status!=HC_STARTUP_FAILED){errno=EPROTO;return -1;}
   if(time_left(&start,timeout_ms)<0||child_live(child)!=1)return -1;
   *out=status;return 0;
  }
  if(errno==EINTR)continue;
  if(errno!=EAGAIN&&errno!=EWOULDBLOCK)return -1;
  struct pollfd p={fd,POLLIN|POLLHUP,0};int rc=poll(&p,1,wait);
  if(rc<0){if(errno==EINTR)continue;return -1;}
  if(rc>0&&(p.revents&(POLLERR|POLLNVAL))){errno=EIO;return -1;}
 }
}
int hc_monitor_startup(int fd,pid_t child,const uint8_t session[16],uint64_t epoch,unsigned timeout_ms,int *out) {
 int status;
 if(!out){errno=EINVAL;return -1;}
 if(hc_monitor_startup_result(fd,child,session,epoch,timeout_ms,&status))return -1;
 if(status!=HC_STARTUP_OK){errno=EPROTO;return -1;}
 *out=status;return 0;
}
int hc_monitor_exit_failure(int fd,pid_t child,const uint8_t session[16],uint64_t epoch,unsigned timeout_ms) {
 int status;
 if(hc_monitor_startup_result(fd,child,session,epoch,timeout_ms,&status))return -1;
 if(status!=HC_STARTUP_FAILED){errno=EPROTO;return -1;}
 return 0;
}
