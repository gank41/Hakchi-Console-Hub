#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#include "playtime.h"
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
int hc_playtime_parse(const void *bytes,size_t length,uint64_t *output){
 if(!bytes||!output||!length||length>21){errno=EINVAL;return -1;}
 const unsigned char *p=bytes;if(p[length-1]=='\n')length--;
 if(!length||length>20){errno=EINVAL;return -1;}
 uint64_t value=0;
 for(size_t i=0;i<length;i++){
  if(p[i]<'0'||p[i]>'9'){errno=EINVAL;return -1;}
  unsigned digit=(unsigned)(p[i]-'0');if(value>(UINT64_MAX-digit)/10){errno=EOVERFLOW;return -1;}
  value=value*10+digit;
 }
 *output=value;return 0;
}
static int same_file(const struct stat *a,const struct stat *b){
 if(a->st_dev!=b->st_dev||a->st_ino!=b->st_ino||a->st_uid!=b->st_uid||a->st_mode!=b->st_mode||a->st_nlink!=b->st_nlink||a->st_size!=b->st_size)return 0;
#ifdef __APPLE__
 return a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec&&a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec&&a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec&&a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec;
#else
 return a->st_mtim.tv_sec==b->st_mtim.tv_sec&&a->st_mtim.tv_nsec==b->st_mtim.tv_nsec&&a->st_ctim.tv_sec==b->st_ctim.tv_sec&&a->st_ctim.tv_nsec==b->st_ctim.tv_nsec;
#endif
}
static int read_exact(int fd,unsigned char *buffer,size_t length){
 for(size_t offset=0;offset<length;){ssize_t n=pread(fd,buffer+offset,length-offset,(off_t)offset);if(n<0&&errno==EINTR)continue;if(n<=0)return -1;offset+=(size_t)n;}return 0;
}
int hc_playtime_read(int fd,uint64_t *output){
 struct stat before,middle,after;unsigned char first[21],second[21];uint64_t value;int flags=fcntl(fd,F_GETFL),descriptor=fcntl(fd,F_GETFD);
 if(!output||fd<3||flags<0||(flags&O_ACCMODE)!=O_RDONLY||descriptor<0||!(descriptor&FD_CLOEXEC)||fstat(fd,&before)||!S_ISREG(before.st_mode)||
    before.st_uid!=geteuid()||before.st_nlink!=1||(before.st_mode&0022)||before.st_size<=0||before.st_size>(off_t)sizeof first){errno=EINVAL;return -1;}
 size_t n=(size_t)before.st_size;
 if(read_exact(fd,first,n)||fstat(fd,&middle)||!same_file(&before,&middle)||read_exact(fd,second,n)||
    fstat(fd,&after)||!same_file(&before,&after)||memcmp(first,second,n)||hc_playtime_parse(first,n,&value)){errno=EIO;return -1;}
 *output=value;return 0;
}
int hc_playtime_accumulate(uint64_t prior,HCPlaytimeInstant start,HCPlaytimeInstant end,uint64_t *output){
 if(!output||start.nanoseconds>=1000000000u||end.nanoseconds>=1000000000u||end.seconds<start.seconds||
    (end.seconds==start.seconds&&end.nanoseconds<start.nanoseconds)){errno=EINVAL;return -1;}
 uint64_t elapsed=end.seconds-start.seconds;if(end.nanoseconds<start.nanoseconds)elapsed--;
 if(prior>UINT64_MAX-elapsed){errno=EOVERFLOW;return -1;}
 *output=prior+elapsed;return 0;
}
int hc_playtime_format(uint64_t value,void *output,size_t capacity,size_t *length){
 if(!output||!length){errno=EINVAL;return -1;}
 char reverse[20],text[20];size_t n=0;do{reverse[n++]=(char)('0'+value%10);value/=10;}while(value);
 if(capacity<n){errno=ENOSPC;return -1;}
 for(size_t i=0;i<n;i++)text[i]=reverse[n-i-1];memcpy(output,text,n);*length=n;return 0;
}
