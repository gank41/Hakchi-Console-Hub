#define _POSIX_C_SOURCE 200809L
#include "stock-previous-save.h"
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#if defined(__APPLE__)
#define HC_MTIME(x) ((x).st_mtimespec)
#define HC_CTIME(x) ((x).st_ctimespec)
#else
#define HC_MTIME(x) ((x).st_mtim)
#define HC_CTIME(x) ((x).st_ctim)
#endif
static int same(const struct stat *a,const struct stat *b){
 return a->st_dev==b->st_dev&&a->st_ino==b->st_ino&&a->st_size==b->st_size&&a->st_mode==b->st_mode&&a->st_uid==b->st_uid&&a->st_nlink==b->st_nlink&&
 HC_MTIME(*a).tv_sec==HC_MTIME(*b).tv_sec&&HC_MTIME(*a).tv_nsec==HC_MTIME(*b).tv_nsec&&HC_CTIME(*a).tv_sec==HC_CTIME(*b).tv_sec&&HC_CTIME(*a).tv_nsec==HC_CTIME(*b).tv_nsec;
}
static int session_ok(HCStockGameSession *s){
 if(!s||strnlen(s->game,sizeof s->game)!=11||strnlen(s->rom.sha256,sizeof s->rom.sha256)!=64||!s->epoch||
    !s->save.stage_size||s->save.stage_size>4u*1024u*1024u||!s->save.target.ready||s->save.target.parent<3||
    strnlen(s->save.target.destination,sizeof s->save.target.destination)!=11||strcmp(s->save.target.destination,"battery.srm"))return 0;
 unsigned token=0;for(size_t i=0;i<sizeof s->token;i++)token|=s->token[i];return token!=0;
}
int hc_stock_previous_capture(HCStockPrevious *p,HCStockGameSession *s){
 struct stat dir,before,opened,after,named;unsigned char *bytes=NULL;int fd=-1,ok=0,present=0;
 if(!p||p->ready||p->owner||p->bytes||p->length||!session_ok(s)||s->save.phase!=HC_STOCK_PREPARED||hc_stock_game_recheck(s)){errno=EINVAL;return -1;}
 int parent=s->save.target.parent;const char *name=s->save.target.destination;
 if(fstat(parent,&dir)||!S_ISDIR(dir.st_mode)||dir.st_uid!=geteuid()||(dir.st_mode&0777)!=0700)goto done;
 if(fstatat(parent,name,&before,AT_SYMLINK_NOFOLLOW)){
  if(errno!=ENOENT)goto done;
  if(!fstatat(parent,name,&named,AT_SYMLINK_NOFOLLOW)||errno!=ENOENT)goto done;
  ok=1;goto done;
 }
 if(!S_ISREG(before.st_mode)||before.st_uid!=geteuid()||before.st_nlink!=1||(before.st_mode&0022)||before.st_size!=(off_t)s->save.stage_size)goto done;
 fd=openat(parent,name,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(fd<0)goto done;
 if(fstat(fd,&opened)||!same(&before,&opened))goto done;
 bytes=malloc(s->save.stage_size);if(!bytes)goto done;
 for(size_t pos=0;pos<s->save.stage_size;){ssize_t n=pread(fd,bytes+pos,s->save.stage_size-pos,(off_t)pos);if(n<0&&errno==EINTR)continue;if(n<=0)goto done;pos+=(size_t)n;}
 if(fstat(fd,&after)||!same(&opened,&after)||fstatat(parent,name,&named,AT_SYMLINK_NOFOLLOW)||!same(&opened,&named))goto done;
 present=1;ok=1;
done:
 if(fd>=0&&close(fd))ok=0;
 if(!ok){free(bytes);errno=EIO;return -1;}
 p->owner=s;p->bytes=bytes;p->length=present?s->save.stage_size:0;p->present=present;
 memcpy(p->game,s->game,sizeof p->game);memcpy(p->digest,s->rom.sha256,sizeof p->digest);memcpy(p->token,s->token,sizeof p->token);p->epoch=s->epoch;p->ready=1;return 0;
}
int hc_stock_previous_validate(HCStockPrevious *p,HCStockGameSession *s){
 if(!p||!p->ready||p->owner!=s||!session_ok(s)||memcmp(p->game,s->game,sizeof p->game)||memcmp(p->digest,s->rom.sha256,sizeof p->digest)||
    memcmp(p->token,s->token,sizeof p->token)||p->epoch!=s->epoch||p->present!=(p->bytes!=NULL)||
    (p->present?p->length!=s->save.stage_size:p->length!=0)){errno=EINVAL;return -1;}
 return 0;
}
int hc_stock_previous_finish(HCStockPrevious *p,HCStockGameSession *s,HCStockControlSession *c){
 if(!c||hc_stock_previous_validate(p,s)){errno=EINVAL;return -1;}
 if(s->save.phase==HC_STOCK_REAPED_CLEAN)return hc_stock_entry_publish_and_finish(s,c,p->bytes,p->length);
 if(s->save.phase==HC_STOCK_REAPED_NO_SRAM)return hc_stock_entry_finish_no_sram(s,c,p->bytes,p->length);
 errno=EINVAL;return -1;
}
void hc_stock_previous_clear(HCStockPrevious *p){if(p){free(p->bytes);memset(p,0,sizeof *p);}}
