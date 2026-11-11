#define _POSIX_C_SOURCE 200809L
#include "stock-reset-input.h"
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
int hc_stock_reset_init(HCStockResetInput *s,int fd,uint16_t key){
 int flags;if(!s||s->fd!=-1||fd<3||key==0||key>767||(flags=fcntl(fd,F_GETFL))<0||(flags&O_ACCMODE)!=O_RDONLY||!(flags&O_NONBLOCK)){errno=EINVAL;return -1;}
 s->fd=fd;s->key=key;return 0;
}
int hc_stock_reset_poll(HCStockResetInput *s){
 if(!s||s->fd<3||!s->key||s->failed){errno=EINVAL;return -1;}
 int triggered=0;
 for(unsigned count=0;count<64;count++){
  ssize_t n=read(s->fd,s->pending+s->used,16-s->used);
  if(n<0){if(errno==EINTR)continue;if(errno==EAGAIN||errno==EWOULDBLOCK)return triggered;s->failed=1;return -1;}
  if(!n){s->failed=1;errno=EIO;return -1;}
  s->used+=(size_t)n;if(s->used<16)continue;
  unsigned type=(unsigned)s->pending[8]|((unsigned)s->pending[9]<<8);
  unsigned code=(unsigned)s->pending[10]|((unsigned)s->pending[11]<<8);
  uint32_t value=(uint32_t)s->pending[12]|((uint32_t)s->pending[13]<<8)|((uint32_t)s->pending[14]<<16)|((uint32_t)s->pending[15]<<24);s->used=0;
  if(type==0&&code==3){s->failed=1;errno=EIO;return -1;} /* SYN_DROPPED */
  if(type==1&&code==s->key){
   if(value==0){s->pressed=0;continue;}
   if(value==2)continue;
   if(value!=1){s->failed=1;errno=EIO;return -1;}
   if(!s->pressed){s->pressed=1;triggered=1;}
  }
 }
 /* Hitting the budget does not prove the stream is drained. */
 s->failed=1;errno=EOVERFLOW;return -1;
}
