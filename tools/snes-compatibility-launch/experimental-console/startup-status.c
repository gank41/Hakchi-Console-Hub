#define _POSIX_C_SOURCE 200809L
#include "startup-status.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

enum { HC_READER_NEW, HC_READER_READING, HC_READER_COMPLETE, HC_READER_DONE, HC_READER_ERROR };
static int nonzero(const uint8_t s[16]) {unsigned x=0;for(size_t i=0;i<16;i++)x|=s[i];return x!=0;}
int hc_startup_encode(uint8_t out[HC_STARTUP_FRAME_SIZE],const uint8_t session[16],uint64_t epoch,int status) {
 if(!out||!session||!nonzero(session)||!epoch||(status!=HC_STARTUP_OK&&status!=HC_STARTUP_FAILED)) {errno=EINVAL;return -1;}
 uint8_t b[HC_STARTUP_FRAME_SIZE]={0};memcpy(b,"HCS1",4);memcpy(b+4,session,16);
 for(int i=0;i<8;i++)b[20+i]=(uint8_t)(epoch>>(56-8*i));
 b[28]=(uint8_t)status;memcpy(out,b,sizeof b);return 0;
}
int hc_startup_reader_init(HCStartupReader *r,const uint8_t session[16],uint64_t epoch) {
 if(!r||!session||!nonzero(session)||!epoch){errno=EINVAL;return -1;}
 if(r->phase!=HC_READER_NEW){r->phase=HC_READER_ERROR;errno=EINVAL;return -1;}
 HCStartupReader n=HC_STARTUP_READER_INIT;memcpy(n.expected_session,session,16);n.expected_epoch=epoch;n.phase=HC_READER_READING;*r=n;return 0;
}
int hc_startup_feed(HCStartupReader *r,const void *data,size_t n) {
 if(!r||r->phase!=HC_READER_READING||r->used>=HC_STARTUP_FRAME_SIZE||!data||!n||n>HC_STARTUP_FRAME_SIZE-r->used){if(r)r->phase=HC_READER_ERROR;errno=EINVAL;return -1;}
 memmove(r->frame+r->used,data,n);r->used+=n;
 if(r->used==HC_STARTUP_FRAME_SIZE){
  uint8_t expected[HC_STARTUP_FRAME_SIZE];int code=r->frame[28];
  if(hc_startup_encode(expected,r->expected_session,r->expected_epoch,code)!=0 || memcmp(expected,r->frame,sizeof expected)){
   r->phase=HC_READER_ERROR;errno=EPROTO;return -1;
  }
  r->phase=HC_READER_COMPLETE;
 }
 return 0;
}
int hc_startup_eof(HCStartupReader *r) {
 if(!r||r->phase!=HC_READER_COMPLETE){if(r)r->phase=HC_READER_ERROR;errno=EPROTO;return -1;}
 int status=r->frame[28];r->phase=HC_READER_DONE;return status;
}
int hc_startup_send(int fd,const uint8_t session[16],uint64_t epoch,int status) {
 uint8_t frame[HC_STARTUP_FRAME_SIZE];struct stat st;struct sigaction action;
 if(fd<3||hc_startup_encode(frame,session,epoch,status)!=0)return -1;
 int flags=fcntl(fd,F_GETFL);
 if(flags<0||(flags&O_ACCMODE)!=O_WRONLY||!(flags&O_NONBLOCK)||fstat(fd,&st)!=0||!S_ISFIFO(st.st_mode)||
    sigaction(SIGPIPE,NULL,&action)!=0||action.sa_handler!=SIG_IGN){errno=EINVAL;return -1;}
 long limit=fpathconf(fd,_PC_PIPE_BUF);if(limit<(long)sizeof frame){errno=EINVAL;return -1;}
 /* An interrupted write transferred no bytes. Retry a bounded number of
  * times; short writes and a persistently interrupted channel still fail. */
 ssize_t n;unsigned attempts=0;
 do {n=write(fd,frame,sizeof frame);attempts++;} while(n<0&&errno==EINTR&&attempts<4);
 if(n!=(ssize_t)sizeof frame){if(n>=0)errno=EIO;return -1;}return 0;
}
