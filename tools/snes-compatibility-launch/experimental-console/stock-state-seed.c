#define _POSIX_C_SOURCE 200809L
#include "stock-state-seed.h"
#include "state_codec.h"
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
static int same(const struct stat *a,const struct stat *b){
 if(a->st_dev!=b->st_dev||a->st_ino!=b->st_ino||a->st_uid!=b->st_uid||a->st_mode!=b->st_mode||a->st_nlink!=b->st_nlink||a->st_size!=b->st_size)return 0;
#ifdef __APPLE__
 return a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec&&a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec&&a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec&&a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec;
#else
 return a->st_mtim.tv_sec==b->st_mtim.tv_sec&&a->st_mtim.tv_nsec==b->st_mtim.tv_nsec&&a->st_ctim.tv_sec==b->st_ctim.tv_sec&&a->st_ctim.tv_nsec==b->st_ctim.tv_nsec;
#endif
}
int hc_stock_state_seed(HCStockGameSession *game,const char *code,const char *digest,const void *input,size_t length){
 static const char name[]="210.state.auto";HCStateBytes decoded=HC_STATE_BYTES_INITIALIZER;
 struct stat dir,after,file,named;int fd=-1,created=0,result=-1;unsigned char check[4096];
 if(!game||!code||!digest||!input||game->autoload_bytes||game->autoload_length||game->save.phase!=HC_STOCK_PREPARED||game->save.stage_dir<3||
    strnlen(code,12)!=11||strnlen(digest,65)!=64||strcmp(code,game->game)||strcmp(digest,game->rom.sha256)||
    hc_stock_game_recheck(game)||fstat(game->save.stage_dir,&dir)||!S_ISDIR(dir.st_mode)||dir.st_uid!=geteuid()||(dir.st_mode&0777)!=0700){errno=EINVAL;return -1;}
 if(!fstatat(game->save.stage_dir,name,&named,AT_SYMLINK_NOFOLLOW)||errno!=ENOENT){errno=EEXIST;return -1;}
 if(hc_state_decode(input,length,&decoded))return -1;
 fd=openat(game->save.stage_dir,name,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0)goto done;created=1;
 for(size_t pos=0;pos<decoded.length;){ssize_t n=write(fd,decoded.data+pos,decoded.length-pos);if(n<0&&errno==EINTR)continue;if(n<=0)goto done;pos+=(size_t)n;}
 if(fsync(fd)||fstat(fd,&file)||!S_ISREG(file.st_mode)||file.st_uid!=geteuid()||(file.st_mode&0777)!=0600||file.st_nlink!=1||file.st_size!=(off_t)decoded.length)goto done;
 for(size_t pos=0;pos<decoded.length;){size_t part=decoded.length-pos;if(part>sizeof check)part=sizeof check;
  ssize_t n=pread(fd,check,part,(off_t)pos);if(n<0&&errno==EINTR)continue;if(n<=0||memcmp(check,decoded.data+pos,(size_t)n))goto done;pos+=(size_t)n;}
 if(fstat(fd,&after)||!same(&file,&after)||fstatat(game->save.stage_dir,name,&named,AT_SYMLINK_NOFOLLOW)||!same(&file,&named)||
    fsync(game->save.stage_dir)||fstat(game->save.stage_dir,&after)||dir.st_dev!=after.st_dev||dir.st_ino!=after.st_ino||dir.st_uid!=after.st_uid||dir.st_mode!=after.st_mode||hc_stock_game_recheck(game))goto done;
 result=0;
done: {int saved=errno;if(fd>=0&&close(fd))result=-1;
 if(!result){game->autoload_bytes=decoded.data;game->autoload_length=decoded.length;game->autoload_snapshot=file;decoded.data=NULL;decoded.length=0;}
 hc_state_bytes_clear(&decoded);
 if(result&&created){game->fault=1;game->save.phase=HC_STOCK_FAILED;errno=saved?saved:EIO;return -2;}
 if(result)errno=saved?saved:EIO;return result;}
}
