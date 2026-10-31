#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#include "core_deletion.h"
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "mbedtls/sha256.h"
static int component(const char *s){if(!s||!s[0]||!strcmp(s,".")||!strcmp(s,".."))return 0;size_t n=0;while(s[n]&&n<128){unsigned char c=(unsigned char)s[n++];if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='-'||c=='_'||c=='.'))return 0;}return n<128;}
static int safe(const struct stat *s,uid_t owner){return S_ISREG(s->st_mode)&&s->st_uid==owner&&s->st_nlink==1&&!(s->st_mode&0022);}
#if defined(__APPLE__)
#define HC_MTIME(s) ((s)->st_mtimespec)
#define HC_CTIME(s) ((s)->st_ctimespec)
#else
#define HC_MTIME(s) ((s)->st_mtim)
#define HC_CTIME(s) ((s)->st_ctim)
#endif
static int same_content_metadata(const HCCoreDeletion *c,const struct stat *s){return s->st_size>=0&&(uint64_t)s->st_size==c->size&&HC_MTIME(s).tv_sec==c->msec&&HC_MTIME(s).tv_nsec==c->mnsec&&HC_CTIME(s).tv_sec==c->csec&&HC_CTIME(s).tv_nsec==c->cnsec;}
static int digest_file(int fd,uint64_t length,uint8_t out[32]){
 if(length>128u*1024u*1024u)return -1;mbedtls_sha256_context h;mbedtls_sha256_init(&h);
 if(mbedtls_sha256_starts(&h,0)!=0){mbedtls_sha256_free(&h);return -1;}
 uint8_t buf[4096];uint64_t off=0;int ok=1;
 while(off<length){size_t n=(size_t)(length-off);if(n>sizeof buf)n=sizeof buf;ssize_t r=pread(fd,buf,n,(off_t)off);
  if(r<0&&errno==EINTR)continue;if(r<=0||mbedtls_sha256_update(&h,buf,(size_t)r)!=0){ok=0;break;}off+=(uint64_t)r;}
 if(ok&&mbedtls_sha256_finish(&h,out)!=0)ok=0;mbedtls_sha256_free(&h);return ok?0:-1;
}
int hc_core_deletion_prepare(HCCoreDeletion *c,int parent,const char *name,uid_t owner,const uint8_t session[16],uint64_t sequence){
 struct stat dir,before,after;int flags=fcntl(parent,F_GETFD);
 unsigned any=0;if(session)for(size_t i=0;i<16;i++)any|=session[i];
 if(!c||c->phase||!session||!any||!sequence||!component(name)||flags<0||!(flags&FD_CLOEXEC)||fstat(parent,&dir)!=0||!S_ISDIR(dir.st_mode)||dir.st_uid!=owner||(dir.st_mode&0022)){errno=EINVAL;return -1;}
 if(fstatat(parent,name,&before,AT_SYMLINK_NOFOLLOW)!=0||!safe(&before,owner)){errno=EACCES;return -1;}
 int fd=openat(parent,name,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return -1;
 if(fstat(fd,&after)!=0||!safe(&after,owner)||after.st_size<0||before.st_dev!=after.st_dev||before.st_ino!=after.st_ino||before.st_size!=after.st_size||HC_MTIME(&before).tv_sec!=HC_MTIME(&after).tv_sec||HC_MTIME(&before).tv_nsec!=HC_MTIME(&after).tv_nsec||HC_CTIME(&before).tv_sec!=HC_CTIME(&after).tv_sec||HC_CTIME(&before).tv_nsec!=HC_CTIME(&after).tv_nsec){close(fd);errno=EIO;return -1;}
 HCCoreDeletion next=HC_CORE_DELETION_INITIALIZER;next.parent=parent;next.file=fd;next.owner=owner;next.device=(uint64_t)after.st_dev;next.inode=(uint64_t)after.st_ino;next.size=(uint64_t)after.st_size;next.sequence=sequence;next.msec=HC_MTIME(&after).tv_sec;next.mnsec=HC_MTIME(&after).tv_nsec;next.csec=HC_CTIME(&after).tv_sec;next.cnsec=HC_CTIME(&after).tv_nsec;memcpy(next.session,session,16);
 if(digest_file(fd,next.size,next.digest)!=0||fstat(fd,&after)!=0||!same_content_metadata(&next,&after)){close(fd);errno=EIO;return -1;}
 next.phase=1;strcpy(next.name,name);*c=next;return 0;
}
int hc_core_deletion_commit(HCCoreDeletion *c,const uint8_t session[16],uint64_t sequence,int unloaded){
 struct stat held,entry,dir;uint8_t digest[32];
 if(!c||c->phase!=1||!session||memcmp(session,c->session,16)||sequence!=c->sequence||unloaded!=1){errno=EINVAL;return -1;}
 if(fstat(c->parent,&dir)!=0||!S_ISDIR(dir.st_mode)||dir.st_uid!=c->owner||(dir.st_mode&0022)||
    fstat(c->file,&held)!=0||!safe(&held,c->owner)||fstatat(c->parent,c->name,&entry,AT_SYMLINK_NOFOLLOW)!=0||!safe(&entry,c->owner)||
    (uint64_t)held.st_dev!=c->device||(uint64_t)held.st_ino!=c->inode||entry.st_dev!=held.st_dev||entry.st_ino!=held.st_ino||!same_content_metadata(c,&held)||!same_content_metadata(c,&entry)){errno=EIO;return -1;}
 if(digest_file(c->file,c->size,digest)!=0||memcmp(digest,c->digest,sizeof digest)||fstat(c->file,&held)!=0||!same_content_metadata(c,&held)){errno=EIO;return -1;}
 #ifdef HC_CORE_TEST_INJECT
 extern int hc_test_core_unlink_failure,hc_test_core_sync_failure;
 if(hc_test_core_unlink_failure){errno=EIO;return -1;}
 #endif
 if(unlinkat(c->parent,c->name,0)!=0)return -1;c->phase=2;
 #ifdef HC_CORE_TEST_INJECT
 if(hc_test_core_sync_failure){errno=EIO;return -2;}
 #endif
 if(fsync(c->parent)!=0){errno=EIO;return -2;}return 0;
}
int hc_core_deletion_close(HCCoreDeletion *c){if(!c||!c->phase){errno=EINVAL;return -1;}int r=close(c->file);c->phase=0;return r;}
