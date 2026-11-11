#define _POSIX_C_SOURCE 200809L
#include "stock-power-input.h"
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
int hc_stock_power_init(HCStockPowerInput *s,int fd,uint16_t type,uint16_t code,uint32_t value){
 int flags;if(!s||s->fd!=-1||fd<3||(type!=1&&type!=5)||code>767||value>1||(flags=fcntl(fd,F_GETFL))<0||(flags&O_ACCMODE)!=O_RDONLY||!(flags&O_NONBLOCK)){errno=EINVAL;return -1;}
 s->fd=fd;s->type=type;s->code=code;s->value=value;return 0;
}
int hc_stock_power_poll(HCStockPowerInput *s){
 if(!s||s->fd<3||s->failed){errno=EINVAL;return -1;}
 int triggered=0;
 for(unsigned count=0;count<64;count++){
  ssize_t n=read(s->fd,s->pending+s->used,16-s->used);
  if(n<0){if(errno==EINTR)continue;if(errno==EAGAIN||errno==EWOULDBLOCK)return triggered;s->failed=1;return -1;}
  if(!n){s->failed=1;errno=EIO;return -1;}
  s->used+=(size_t)n;if(s->used<16)continue;
  unsigned type=(unsigned)s->pending[8]|((unsigned)s->pending[9]<<8);
  unsigned code=(unsigned)s->pending[10]|((unsigned)s->pending[11]<<8);
  uint32_t value=(uint32_t)s->pending[12]|((uint32_t)s->pending[13]<<8)|((uint32_t)s->pending[14]<<16)|((uint32_t)s->pending[15]<<24);s->used=0;
  if(type==0&&code==3){s->failed=1;errno=EIO;return -1;}
  if(type==s->type&&code==s->code){if(value>2||(type==5&&value>1)){s->failed=1;errno=EIO;return -1;}if(value==s->value&&!s->triggered){s->triggered=1;triggered=1;}}
 }
 /* Hitting the budget does not prove the stream is drained. */
 s->failed=1;errno=EOVERFLOW;return -1;
}
