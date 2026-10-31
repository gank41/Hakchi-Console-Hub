#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#include "autosave_verify.h"
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
static int valid(const struct stat *s,uid_t owner,size_t n){return S_ISREG(s->st_mode)&&s->st_uid==owner&&s->st_nlink==1&&!(s->st_mode&0022)&&s->st_size==(off_t)n;}
int hc_autosave_verify(const char *path,uid_t owner,const void *expected,size_t n){
 struct stat before,openst,after;unsigned char buf[4096];
 if(!path||path[0]!='/'||!expected||!n||n>16u*1024u*1024u){errno=EINVAL;return -1;}
 if(lstat(path,&before)!=0 || !valid(&before,owner,n)){errno=EACCES;return -1;}
 int fd=open(path,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return -1;
 if(fstat(fd,&openst)!=0||!valid(&openst,owner,n)||before.st_dev!=openst.st_dev||before.st_ino!=openst.st_ino)goto fail;
 if(fsync(fd)!=0)goto fail;
 for(size_t off=0;off<n;){size_t amount=n-off;if(amount>sizeof buf)amount=sizeof buf;
  ssize_t got=pread(fd,buf,amount,(off_t)off);if(got<0&&errno==EINTR)continue;
  if(got<=0||memcmp(buf,(const unsigned char *)expected+off,(size_t)got))goto fail;off+=(size_t)got;}
 if(fstat(fd,&after)!=0||!valid(&after,owner,n)||after.st_dev!=openst.st_dev||after.st_ino!=openst.st_ino)goto fail;
 if(close(fd)!=0)return -1;return 0;
fail: close(fd);errno=EIO;return -1;
}
