#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#include "verified-launch.h"
#include "mbedtls/sha256.h"
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#if defined(__APPLE__)
#define MT(x) ((x).st_mtimespec)
#define CT(x) ((x).st_ctimespec)
#else
#define MT(x) ((x).st_mtim)
#define CT(x) ((x).st_ctim)
#endif
static int same(const struct stat *a,const struct stat *b){return a->st_dev==b->st_dev&&a->st_ino==b->st_ino&&a->st_size==b->st_size&&a->st_mode==b->st_mode&&a->st_uid==b->st_uid&&a->st_nlink==b->st_nlink&&MT(*a).tv_sec==MT(*b).tv_sec&&MT(*a).tv_nsec==MT(*b).tv_nsec&&CT(*a).tv_sec==CT(*b).tv_sec&&CT(*a).tv_nsec==CT(*b).tv_nsec;}
static int name_ok(const char *n){if(!n||!*n||!strcmp(n,".")||!strcmp(n,".."))return 0;size_t i=0;for(;i<128&&n[i];i++){unsigned char c=(unsigned char)n[i];if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='-'||c=='_'||c=='.'))return 0;}return i>0&&i<128;}
static int digest(int fd,off_t size,char out[65]){mbedtls_sha256_context h;uint8_t bytes[32],buf[8192];off_t off=0;int ok=1;static const char hex[]="0123456789abcdef";mbedtls_sha256_init(&h);if(mbedtls_sha256_starts(&h,0))ok=0;while(ok&&off<size){size_t want=(size_t)(size-off);if(want>sizeof buf)want=sizeof buf;ssize_t n=pread(fd,buf,want,off);if(n<0&&errno==EINTR)continue;if(n<=0||mbedtls_sha256_update(&h,buf,(size_t)n))ok=0;else off+=n;}if(ok&&mbedtls_sha256_finish(&h,bytes))ok=0;mbedtls_sha256_free(&h);if(!ok)return -1;for(size_t i=0;i<32;i++){out[2*i]=hex[bytes[i]>>4];out[2*i+1]=hex[bytes[i]&15];}out[64]=0;return 0;}
int hc_verified_rom_open(HCVerifiedLaunch *v,int d,const char *name,uid_t uid,const char *expected){
 struct stat dir,before,opened,after,named;char actual[65];int fd=-1,parent=-1;
 if(!v||v->ready||!name_ok(name)||!expected||strnlen(expected,65)!=64||fcntl(d,F_GETFD)<0||!(fcntl(d,F_GETFD)&FD_CLOEXEC)||fstat(d,&dir)||!S_ISDIR(dir.st_mode)||dir.st_uid!=uid||(dir.st_mode&0022)){errno=EINVAL;return -1;}
 if(fstatat(d,name,&before,AT_SYMLINK_NOFOLLOW)||!S_ISREG(before.st_mode)||before.st_uid!=uid||before.st_nlink!=1||(before.st_mode&0022)||before.st_size<=0||before.st_size>4*1024*1024+512){errno=EINVAL;return -1;}
 fd=openat(d,name,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return -1;
 if(fstat(fd,&opened)||!same(&before,&opened)||digest(fd,opened.st_size,actual)||strcmp(actual,expected))goto fail;
#ifdef HC_LAUNCH_TEST_AFTER_HASH
 {extern void hc_test_launch_after_hash(void);hc_test_launch_after_hash();}
#endif
 if(fstat(fd,&after)||fstatat(d,name,&named,AT_SYMLINK_NOFOLLOW)||!same(&opened,&after)||!same(&opened,&named))goto fail;
 parent=fcntl(d,F_DUPFD_CLOEXEC,3);if(parent<0)goto fail;
 v->rom_fd=fd;v->parent=parent;v->snapshot=opened;strcpy(v->name,name);memcpy(v->sha256,actual,65);v->ready=1;return 0;
fail: {int saved=errno;if(parent>=0)close(parent);close(fd);errno=saved?saved:EIO;return -1;}
}
int hc_verified_launch_prepare(HCVerifiedLaunch *v,HCSessionOwner *o,int d,const char *name,uid_t uid,const char *game,const char *expected,const HCSessionExpected *regions,size_t count,HCSessionRetention retention,const uint8_t token[16],uint64_t epoch,int binding_dir,const char *binding){
 if(!o){errno=EINVAL;return -1;}
 if(hc_verified_rom_open(v,d,name,uid,expected))return -1;
 if(hc_bound_session_install(o,uid,regions,count,retention,token,epoch,binding_dir,binding,game,v->sha256)||hc_verified_launch_recheck(v)){
  int saved=errno;(void)hc_verified_launch_close(v);errno=saved?saved:EIO;return -1;
 }
 return 0;
}

int hc_verified_launch_recheck(HCVerifiedLaunch *v){struct stat held,named,after;char hash[65];if(!v||!v->ready){errno=EINVAL;return -1;}if(fstat(v->rom_fd,&held)||fstatat(v->parent,v->name,&named,AT_SYMLINK_NOFOLLOW)||!same(&v->snapshot,&held)||!same(&v->snapshot,&named)||digest(v->rom_fd,held.st_size,hash)||strcmp(hash,v->sha256)||fstat(v->rom_fd,&after)||!same(&held,&after)||fstatat(v->parent,v->name,&named,AT_SYMLINK_NOFOLLOW)||!same(&v->snapshot,&named)){errno=EIO;return -1;}return 0;}
/* Caller excludes concurrent descriptor-table reuse during close and retry. */
static int verified_close_owned(int *slot){
 if(*slot<0)return 0;
 int fd=*slot;*slot=-1;
 if(!close(fd))return 0;
 int saved=errno;errno=0;
 if(fcntl(fd,F_GETFD)!=-1||errno!=EBADF)*slot=fd;
 errno=saved?saved:EIO;return -1;
}
int hc_verified_launch_close(HCVerifiedLaunch *v){
 if(!v||!v->ready){errno=EINVAL;return -1;}
 if(verified_close_owned(&v->rom_fd)||verified_close_owned(&v->parent))return -1;
 v->ready=0;return 0;
}
/* The inherited descriptor is borrowed. A duplicated descriptor becomes the
 * launch source; pathname and descriptor must both identify the same inode.
 * The caller still supplies authenticated metadata and exclusive file access. */
int hc_verified_launch_prepare_inherited(HCVerifiedLaunch *v,HCSessionOwner *o,int d,const char *name,int inherited,uid_t uid,const char *game,const char *expected,const HCSessionExpected *regions,size_t count,HCSessionRetention retention,const uint8_t token[16],uint64_t epoch,int binding_dir,const char *binding){
 struct stat source,named,again;int flags=fcntl(inherited,F_GETFL),copy=-1;
 if(!v||v->ready||!name_ok(name)||flags<0||(flags&O_ACCMODE)!=O_RDONLY||fstat(inherited,&source)||fstatat(d,name,&named,AT_SYMLINK_NOFOLLOW)||!S_ISREG(source.st_mode)||!same(&source,&named)){errno=EINVAL;return -1;}
 copy=fcntl(inherited,F_DUPFD_CLOEXEC,3);if(copy<0)return -1;
 if(fstat(copy,&again)||!same(&source,&again)){close(copy);errno=EIO;return -1;}
 if(hc_verified_launch_prepare(v,o,d,name,uid,game,expected,regions,count,retention,token,epoch,binding_dir,binding)){int saved=errno;close(copy);errno=saved;return -1;}
 if(fstat(copy,&again)||!same(&v->snapshot,&again)){close(copy);errno=EIO;return -1;}
 int old=v->rom_fd;v->rom_fd=copy;if(close(old)||hc_verified_launch_recheck(v)){errno=EIO;return -1;}
 return 0;
}
