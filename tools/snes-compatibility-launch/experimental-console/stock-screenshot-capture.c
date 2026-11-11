#define _POSIX_C_SOURCE 200809L
#include "stock-screenshot-capture.h"
#include "atomic_pipe.h"
#include "control_pipe.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#define HC_SHOT_MAX (8u*1024u*1024u)
static int game_identity_valid(const HCStockGameSession *g){
 if(!g||!g->rom.ready||strnlen(g->game,sizeof g->game)!=11||memcmp(g->game,"CLV-U-",6)||strnlen(g->rom.sha256,sizeof g->rom.sha256)!=64)return 0;
 for(size_t i=6;i<11;i++)if(!((g->game[i]>='A'&&g->game[i]<='Z')||(g->game[i]>='0'&&g->game[i]<='9')))return 0;
 for(size_t i=0;i<64;i++)if(!((g->rom.sha256[i]>='0'&&g->rom.sha256[i]<='9')||(g->rom.sha256[i]>='a'&&g->rom.sha256[i]<='f')))return 0;
 return 1;
}
static int resources_unchanged(const HCStockScreenshotReceipt *c){
 struct stat p,d;int pf=fcntl(c->receipt,F_GETFL),pd=fcntl(c->receipt,F_GETFD),dd=fcntl(c->dir,F_GETFD);
 return pf>=0&&(pf&O_ACCMODE)==O_RDONLY&&(pf&O_NONBLOCK)&&pd>=0&&(pd&FD_CLOEXEC)&&dd>=0&&(dd&FD_CLOEXEC)&&
  !fstat(c->receipt,&p)&&S_ISFIFO(p.st_mode)&&p.st_dev==c->receipt_snapshot.st_dev&&p.st_ino==c->receipt_snapshot.st_ino&&
  !fstat(c->dir,&d)&&S_ISDIR(d.st_mode)&&d.st_dev==c->directory_snapshot.st_dev&&d.st_ino==c->directory_snapshot.st_ino&&d.st_uid==c->directory_snapshot.st_uid&&d.st_uid==geteuid()&&(d.st_mode&0777)==0700;
}
static int input_unchanged(const HCStockScreenshotReceipt *c,const HCStockSaveSession *s){
 struct stat current;int flags=fcntl(s->child.input,F_GETFL),fdflags=fcntl(s->child.input,F_GETFD);
 return s->child.pid==c->child_pid&&s->child.input==c->input_fd&&flags>=0&&(flags&O_ACCMODE)==O_WRONLY&&(flags&O_NONBLOCK)&&fdflags>=0&&(fdflags&FD_CLOEXEC)&&
  !fstat(s->child.input,&current)&&S_ISFIFO(current.st_mode)&&current.st_dev==c->input_snapshot.st_dev&&current.st_ino==c->input_snapshot.st_ino;
}
/* Caller excludes all other writers and pathname replacement throughout. */
static int identity(HCStockScreenshotReceipt *c,HCStockSaveSession *save){
 return c&&c->game&&resources_unchanged(c)&&save==&c->game->save&&c->epoch==c->game->epoch&&c->epoch&&
  game_identity_valid(c->game)&&!memcmp(c->game_code,c->game->game,sizeof c->game_code)&&!memcmp(c->rom_digest,c->game->rom.sha256,sizeof c->rom_digest)&&
  !memcmp(c->token,c->game->token,16)&&save->phase==HC_STOCK_RUNNING&&save->child.pid>1&&save->child.input>=3&&(c->phase!=2||input_unchanged(c,save));
}
/* Return the sole entry, rejecting extra files, non-PNG names and overlong names. */
static int image_name(int dir,char name[256],int allow_empty){
 int fd=openat(dir,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return -1;
 DIR *d=fdopendir(fd);if(!d){close(fd);return -1;}struct dirent *e;int count=0,bad=0;errno=0;
 while((e=readdir(d))){if(!strcmp(e->d_name,".")||!strcmp(e->d_name,".."))continue;
  size_t n=strnlen(e->d_name,256);if(++count!=1||n<5||n>=256||strcmp(e->d_name+n-4,".png")){bad=1;break;}
  memcpy(name,e->d_name,n+1);
 }
 if(errno)bad=1;if(closedir(d))bad=1;
 if(bad||count>1||(!allow_empty&&count!=1)){errno=EINVAL;return -1;}return count;
}
int hc_stock_screenshot_receipt_init(HCStockScreenshotReceipt *c,HCStockGameSession *game,int receipt,int dir){
 struct stat p,d;char name[256];int flags=fcntl(receipt,F_GETFL),descriptor=fcntl(receipt,F_GETFD),dirflags=fcntl(dir,F_GETFD);
 if(!c||c->phase||c->game||c->image||!game_identity_valid(game)||!game->epoch||receipt<3||dir<3||receipt==dir||
    flags<0||(flags&O_ACCMODE)!=O_RDONLY||!(flags&O_NONBLOCK)||descriptor<0||!(descriptor&FD_CLOEXEC)||
    dirflags<0||!(dirflags&FD_CLOEXEC)||fstat(receipt,&p)||!S_ISFIFO(p.st_mode)||fstat(dir,&d)||!S_ISDIR(d.st_mode)||d.st_uid!=geteuid()||(d.st_mode&0777)!=0700||image_name(dir,name,1)!=0||
    hc_verified_launch_recheck(&game->rom)||hc_checkpoint_init_image(&c->checkpoint,game->token,1)){errno=EINVAL;return -1;}
 c->game=game;c->receipt=receipt;c->dir=dir;c->receipt_snapshot=p;c->directory_snapshot=d;c->epoch=game->epoch;memcpy(c->token,game->token,16);memcpy(c->game_code,game->game,sizeof c->game_code);memcpy(c->rom_digest,game->rom.sha256,sizeof c->rom_digest);c->phase=1;return 0;
}
static int begin(void *ctx,HCStockSaveSession *save){
 HCStockScreenshotReceipt *c=ctx;char name[256];static const uint8_t command[]="HC_SCREENSHOT 1\n";
 if(!identity(c,save)||c->phase!=1||hc_verified_launch_recheck(&c->game->rom)||image_name(c->dir,name,1)!=0){errno=EINVAL;return -1;}
 uint8_t unexpected;ssize_t pending=read(c->receipt,&unexpected,1);
 if(pending>=0||!(errno==EAGAIN||errno==EWOULDBLOCK)){c->phase=4;errno=EIO;return -1;}
 c->input_fd=save->child.input;c->child_pid=save->child.pid;
 if(fstat(c->input_fd,&c->input_snapshot)||!input_unchanged(c,save)){c->phase=4;errno=EINVAL;return -1;}
 c->phase=2;if(hc_atomic_pipe_write(save->child.input,command,sizeof command-1)) {c->phase=4;return -1;}return 0;
}
static int poll_capture(void *ctx,HCStockSaveSession *save,uint64_t now){
 HCStockScreenshotReceipt *c=ctx;unsigned char frame[32],extra;char name[256];struct stat a,b;int fd=-1;(void)now;
 if(!identity(c,save)||c->phase!=2){errno=EINVAL;return -1;}
 ssize_t n=read(c->receipt,frame,sizeof frame);if(n<0&&(errno==EAGAIN||errno==EWOULDBLOCK||errno==EINTR))return 0;
 if(n<=0){c->phase=4;errno=EIO;return -1;}
 int r=hc_checkpoint_feed(&c->reader,&c->checkpoint,frame,(size_t)n);if(r==0)return 0;
 if(r<0){c->phase=4;return -1;}
 if(hc_verified_launch_recheck(&c->game->rom)){c->phase=4;return -1;}
 n=read(c->receipt,&extra,1);if(n>=0||!(errno==EAGAIN||errno==EWOULDBLOCK)){c->phase=4;errno=EIO;return -1;}
 /* A FIFO masquerading as a PNG must not block the supervisor's deadline. */
 if(image_name(c->dir,name,0)!=1||(fd=openat(c->dir,name,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC))<0||fstat(fd,&a)||!S_ISREG(a.st_mode)||a.st_uid!=geteuid()||a.st_nlink!=1||a.st_size<=0||(uint64_t)a.st_size>HC_SHOT_MAX)goto fail;
 c->image=malloc((size_t)a.st_size);if(!c->image)goto fail;size_t pos=0;
 while(pos<(size_t)a.st_size){n=read(fd,c->image+pos,(size_t)a.st_size-pos);if(n<0&&errno==EINTR)continue;if(n<=0)goto fail;pos+=(size_t)n;}
 struct stat named;char again[256];
 if(fstat(fd,&b)||fstatat(c->dir,name,&named,AT_SYMLINK_NOFOLLOW)||image_name(c->dir,again,0)!=1||strcmp(name,again)||
    a.st_dev!=b.st_dev||a.st_ino!=b.st_ino||a.st_size!=b.st_size||a.st_mode!=b.st_mode||a.st_uid!=b.st_uid||a.st_nlink!=b.st_nlink||a.st_mtime!=b.st_mtime||a.st_ctime!=b.st_ctime||
#if defined(__APPLE__)
    a.st_mtimespec.tv_nsec!=b.st_mtimespec.tv_nsec||a.st_ctimespec.tv_nsec!=b.st_ctimespec.tv_nsec||
#else
    a.st_mtim.tv_nsec!=b.st_mtim.tv_nsec||a.st_ctim.tv_nsec!=b.st_ctim.tv_nsec||
#endif
    a.st_dev!=named.st_dev||a.st_ino!=named.st_ino||a.st_size!=named.st_size||a.st_mode!=named.st_mode||a.st_uid!=named.st_uid||a.st_nlink!=named.st_nlink||
    hc_checkpoint_verify_image(&c->checkpoint,c->image,pos,1))goto fail;
 if(close(fd)){fd=-1;goto fail;}c->image_length=pos;c->phase=3;return 1;
fail:
 if(fd>=0)close(fd);free(c->image);c->image=NULL;c->image_length=0;c->phase=4;errno=EIO;return -1;
}
HCStockScreenshotCapture hc_stock_screenshot_receipt_capture(HCStockScreenshotReceipt *c){HCStockScreenshotCapture result={c,begin,poll_capture};return result;}
int hc_stock_screenshot_bind_session(HCStockGameSession *game,HCStockControlSession *control,HCStockScreenshotReceipt *shot,HCStockScreenshotCapture *capture,int directory,int *reader,int *writer){
 if(!game||!control||control->save!=&game->save||game->save.phase!=HC_STOCK_PREPARED||!shot||!capture||
    capture->context||capture->begin||capture->poll||!reader||!writer||reader==writer||*reader!=-1||*writer!=-1){errno=EINVAL;return -1;}
 int pipefds[2];if(hc_control_pipe(pipefds))return -1;*reader=pipefds[0];*writer=pipefds[1];
 if(hc_stock_screenshot_receipt_init(shot,game,*reader,directory))return -1;
 *capture=hc_stock_screenshot_receipt_capture(shot);
 if(hc_stock_control_attach_screenshot(control,capture)){
  int saved=errno;memset(capture,0,sizeof *capture);hc_stock_screenshot_receipt_clear(shot);errno=saved;return -1;
 }
 if(hc_stock_save_take_screenshot_receipt(&game->save,*writer)){
  int saved=errno;control->screenshot=NULL;memset(capture,0,sizeof *capture);hc_stock_screenshot_receipt_clear(shot);errno=saved;return -1;
 }
 *writer=-1;
 return 0;
}
void hc_stock_screenshot_receipt_clear(HCStockScreenshotReceipt *c){if(c){free(c->image);*c=(HCStockScreenshotReceipt)HC_STOCK_SCREENSHOT_RECEIPT_INITIALIZER;}}
