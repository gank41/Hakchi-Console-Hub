#define _POSIX_C_SOURCE 200809L
#include "stock-manager-image.h"
#include "recovery-binding.h"
#include "screenshot-session-names.h"
#include "nonce-sequence.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#if defined(HC_STOCK_MANAGER_HOST_ROOT) && defined(__arm__)
#error "Manager-path remapping is only for host tests."
#endif
#if defined(HC_STOCK_MANAGER_TEST_HOOK) && defined(__arm__)
#error "Manager-image interruption injection is host-only."
#endif
/* The real console uses the exact recorded path. Host tests map only the
 * recorded volatile prefix into a disposable directory. */
static int image_path(const char *logical,char physical[1024]){
 if(!logical||logical[0]!='/'){errno=EINVAL;return -1;}
#ifdef HC_STOCK_MANAGER_HOST_ROOT
 static const char prefix[]="/var/cache/clover/volatile/";
 if(strncmp(logical,prefix,sizeof prefix-1)){errno=EINVAL;return -1;}
 int n=snprintf(physical,1024,"%s/%s",HC_STOCK_MANAGER_HOST_ROOT,logical+sizeof prefix-1);
#else
 int n=snprintf(physical,1024,"%s",logical);
#endif
 if(n<=0||n>=1024){errno=EINVAL;return -1;}return 0;
}
static int request_matches(HCStockGameSession *game,HCConsoleRuntime *runtime,HCConsoleGame *menu){
 if(!runtime||!menu||!game||!runtime->claimed||runtime->workspace<3||!menu->rom.ready||!menu->command.checkpoint.have_image||
    strcmp(menu->command.game,game->game)||strcmp(menu->command.digest,game->rom.sha256)||strcmp(menu->rom.sha256,game->rom.sha256)||
    strcmp(runtime->request.game,game->game)||strcmp(runtime->request.digest,game->rom.sha256)||memcmp(runtime->request.session,game->token,16)||runtime->request.epoch!=game->epoch||
    hc_verified_launch_recheck(&game->rom)||hc_verified_launch_recheck(&menu->rom)||hc_console_game_check_manager_record_full(runtime->workspace,&runtime->request,&menu->command.checkpoint,&menu->command.time)){errno=EINVAL;return -1;}
 return 0;
}
static int session_matches(HCStockRetainedImage *retained,HCStockGameSession *game,HCStockControlSession *control,HCStockScreenshotReceipt *capture,HCConsoleRuntime *runtime,HCConsoleGame *menu){
 if(request_matches(game,runtime,menu)||hc_stock_retained_image_recheck(retained,game,control,capture)){errno=EINVAL;return -1;}return 0;
}
static int same_seed_stat(const struct stat *a,const struct stat *b){
 if(a->st_dev!=b->st_dev||a->st_ino!=b->st_ino||a->st_uid!=b->st_uid||a->st_mode!=b->st_mode||a->st_nlink!=b->st_nlink||a->st_size!=b->st_size)return 0;
#ifdef __APPLE__
 return a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec&&a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec&&a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec&&a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec;
#else
 return a->st_mtim.tv_sec==b->st_mtim.tv_sec&&a->st_mtim.tv_nsec==b->st_mtim.tv_nsec&&a->st_ctim.tv_sec==b->st_ctim.tv_sec&&a->st_ctim.tv_nsec==b->st_ctim.tv_nsec;
#endif
}
static int same_ascii_path(const char *a,const char *b){
 for(;;a++,b++){unsigned char x=(unsigned char)*a,y=(unsigned char)*b;if(x>='A'&&x<='Z')x=(unsigned char)(x+32);if(y>='A'&&y<='Z')y=(unsigned char)(y+32);if(x!=y)return 0;if(!x)return 1;}
}
static int read_exact_time(int fd,unsigned char *bytes,size_t length){
 for(size_t pos=0;pos<length;){ssize_t n=pread(fd,bytes+pos,length-pos,(off_t)pos);if(n<0&&errno==EINTR)continue;if(n<=0)return -1;pos+=(size_t)n;}return 0;
}
int hc_stock_time_seed_open(HCStockTimeSeed *out,HCStockGameSession *game,HCConsoleRuntime *runtime,HCConsoleGame *menu,int parent){
 char load[1024],save[1024];unsigned char original[21];struct stat held,named,directory;uint64_t value=0;int fd=-1;HCSessionExpected regions[2];
 if(!out||out->ready||out->fd!=-1||out->parent!=-1||!game||game->save.phase!=HC_STOCK_PREPARED||!menu||!menu->command.time.have_load||!menu->command.time.have_save||
    request_matches(game,runtime,menu)||image_path(menu->command.time.load,load)||image_path(menu->command.time.save,save)||parent<3||fcntl(parent,F_GETFD)<0||
    !(fcntl(parent,F_GETFD)&FD_CLOEXEC)||fstat(parent,&directory)||!S_ISDIR(directory.st_mode)||directory.st_uid!=geteuid()||(directory.st_mode&0777)!=0700){errno=EINVAL;return -1;}
 regions[0]=(HCSessionExpected){parent,load,105};regions[1]=(HCSessionExpected){parent,save,104};
 const char *base=strrchr(load,'/');const char *target=strrchr(save,'/');
 int same=same_ascii_path(load,save);
 if(!base||!base[1]||!target||!target[1]||(same?(hc_session_validate_regions(regions,1)||hc_session_validate_regions(regions+1,1)):hc_session_validate_regions(regions,2))){errno=EINVAL;return -1;}
 if(!same&&(!fstatat(parent,target+1,&named,AT_SYMLINK_NOFOLLOW)||errno!=ENOENT)){errno=EINVAL;return -1;}
 fd=openat(parent,base+1,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return -1;
 if(fstat(fd,&held)||fstatat(parent,base+1,&named,AT_SYMLINK_NOFOLLOW)||!same_seed_stat(&held,&named)||hc_playtime_read(fd,&value)||
    held.st_size<=0||held.st_size>(off_t)sizeof original||read_exact_time(fd,original,(size_t)held.st_size)||fstat(fd,&named)||!same_seed_stat(&held,&named)){int saved=errno;close(fd);errno=saved?saved:EIO;return -1;}
 HCStockTimeSeed next=HC_STOCK_TIME_SEED_INITIALIZER;next.ready=1;next.fd=fd;next.parent=parent;next.same_target=same;next.prior=value;next.epoch=game->epoch;next.snapshot=held;
 next.original_length=(size_t)held.st_size;memcpy(next.original,original,next.original_length);
 next.session=game;next.runtime=runtime;next.menu=menu;memcpy(next.token,game->token,16);memcpy(next.game,game->game,sizeof next.game);memcpy(next.digest,game->rom.sha256,sizeof next.digest);strcpy(next.path,load);*out=next;return 0;
}
int hc_stock_time_seed_recheck(HCStockTimeSeed *seed,HCStockGameSession *game,HCConsoleRuntime *runtime,HCConsoleGame *menu,int parent){
 struct stat held,named,dir_a,dir_b;uint64_t value=0;char path[1024],save[1024];unsigned char bytes[21];
 if(!seed||!seed->ready||seed->fd<3||seed->parent<3||seed->session!=game||seed->runtime!=runtime||seed->menu!=menu||parent<3||!game||!menu||
    !menu->command.time.have_load||!menu->command.time.have_save||seed->epoch!=game->epoch||memcmp(seed->token,game->token,16)||
    memcmp(seed->game,game->game,sizeof seed->game)||memcmp(seed->digest,game->rom.sha256,sizeof seed->digest)||request_matches(game,runtime,menu)||
    image_path(menu->command.time.load,path)||image_path(menu->command.time.save,save)||strcmp(path,seed->path)||seed->same_target!=same_ascii_path(path,save)||
    fstat(parent,&dir_a)||fstat(seed->parent,&dir_b)||dir_a.st_dev!=dir_b.st_dev||dir_a.st_ino!=dir_b.st_ino||!S_ISDIR(dir_a.st_mode)||dir_a.st_uid!=geteuid()||(dir_a.st_mode&0777)!=0700){errno=EINVAL;return -1;}
 const char *base=strrchr(seed->path,'/');HCSessionExpected region={parent,seed->path,105};
 if(!base||!base[1]||hc_session_validate_regions(&region,1)||fstat(seed->fd,&held)||fstatat(parent,base+1,&named,AT_SYMLINK_NOFOLLOW)||
    !same_seed_stat(&seed->snapshot,&held)||!same_seed_stat(&held,&named)||hc_playtime_read(seed->fd,&value)||value!=seed->prior||
    !seed->original_length||seed->original_length>sizeof bytes||read_exact_time(seed->fd,bytes,seed->original_length)||memcmp(bytes,seed->original,seed->original_length)||
    fstat(seed->fd,&held)||!same_seed_stat(&seed->snapshot,&held)){errno=EINVAL;return -1;}
 return 0;
}
static int seed_backup_identity(HCStockTimeSeed *seed,HCStockGameSession *game,HCConsoleRuntime *runtime,char path[1024]){
 char expected[44];static const char hex[]="0123456789abcdef";size_t n;
 if(!seed||!game||!runtime||!runtime->claimed||runtime->workspace<3||seed->session!=game||seed->epoch!=game->epoch||memcmp(seed->token,game->token,16)||
    strcmp(seed->game,runtime->request.game)||strcmp(seed->digest,runtime->request.digest)||memcmp(seed->token,runtime->request.session,16)||seed->epoch!=runtime->request.epoch){errno=EINVAL;return -1;}
 memcpy(expected,"checkpoint-",11);for(size_t i=0;i<16;i++){expected[11+2*i]=hex[seed->token[i]>>4];expected[12+2*i]=hex[seed->token[i]&15];}expected[43]=0;
 n=strnlen(game->save.identity,sizeof game->save.identity);
 if(strcmp(runtime->workspace_name,expected)||n<12||n>=sizeof game->save.identity||strcmp(game->save.identity+n-12,"/battery.srm")){errno=EINVAL;return -1;}
 int length=snprintf(path,1024,"%.*s/sessions/%s/time-original",(int)(n-12),game->save.identity,expected);
 if(length<=0||length>=1024){errno=EINVAL;return -1;}return 0;
}
int hc_stock_time_seed_backup_recheck(HCStockTimeSeed *seed,HCStockGameSession *game,HCConsoleRuntime *runtime){
 char path[1024];HCSessionExpected region;HCIV2Entry entries[16];size_t count=0;struct stat held,named;unsigned char bytes[21];uint64_t value=0;int fd=-1,ok=0;
 if(!seed||!seed->backup_retained||seed->backup_runtime!=runtime||!seed->backup.ready||!seed->backup.consumed||
    !seed->original_length||seed->original_length>sizeof bytes||seed_backup_identity(seed,game,runtime,path)||strcmp(path,seed->backup_path)){errno=EINVAL;return -1;}
 region=(HCSessionExpected){runtime->workspace,path,106};
 if(hc_binding_inventory(runtime->workspace,"time-seed-binding",game->game,game->rom.sha256,game->token,game->epoch,&region,1,0,entries,16,&count)||
    count!=1||strcmp(entries[0].region,"time-original")||strcmp(entries[0].workspace,seed->backup.workspace_name)||entries[0].kind!=HCIV2_FINAL||!entries[0].workspace_present)return -1;
 fd=openat(runtime->workspace,"time-original",O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return -1;
 if(fstat(fd,&held)||fstatat(runtime->workspace,"time-original",&named,AT_SYMLINK_NOFOLLOW)||!same_seed_stat(&held,&named)||
    held.st_size!=(off_t)seed->original_length||hc_playtime_read(fd,&value)||value!=seed->prior||read_exact_time(fd,bytes,seed->original_length)||
    memcmp(bytes,seed->original,seed->original_length)||fstat(fd,&named)||!same_seed_stat(&held,&named))goto done;
 ok=1;
done: {int saved=errno;if(close(fd))ok=0;if(!ok){errno=saved?saved:EIO;return -1;}return 0;}
}
int hc_stock_time_seed_retain(HCStockTimeSeed *seed,HCStockGameSession *game,HCConsoleRuntime *runtime){
 HCSessionExpected region;HCNonceSequence sequence=HC_NONCE_SEQUENCE_INITIALIZER;uint8_t nonce[16];struct stat named;
 if(!seed||seed->backup_attempted||seed->backup_retained||seed->backup.ready||!seed->ready||
    hc_stock_time_seed_recheck(seed,game,seed->runtime,seed->menu,seed->parent)||seed_backup_identity(seed,game,runtime,seed->backup_path)){errno=EINVAL;return -1;}
 region=(HCSessionExpected){runtime->workspace,seed->backup_path,106};
 if(hc_session_validate_regions(&region,1)||!fstatat(runtime->workspace,"time-original",&named,AT_SYMLINK_NOFOLLOW)||errno!=ENOENT){errno=EINVAL;return -1;}
 if(hc_nonce_sequence_init(&sequence))return -1;
 int r=hc_nonce_sequence_next(&sequence,nonce),saved=errno;if(hc_nonce_sequence_destroy(&sequence)&&!r){r=-1;saved=errno;}if(r){errno=saved;return -1;}
 char session[33],workspace[44];static const char hex[]="0123456789abcdef";memcpy(workspace,"checkpoint-",11);
 for(size_t i=0;i<16;i++){session[2*i]=hex[game->token[i]>>4];session[2*i+1]=hex[game->token[i]&15];workspace[11+2*i]=hex[nonce[i]>>4];workspace[12+2*i]=hex[nonce[i]&15];}session[32]=0;workspace[43]=0;
 if(!memcmp(nonce,game->token,16)){errno=EINVAL;return -1;}
 seed->backup_attempted=1;seed->backup_runtime=runtime;
 if(hc_binding_create(runtime->workspace,"time-seed-binding",game->game,game->rom.sha256,game->token,game->epoch,&region,1)||
    hciv2_create(runtime->workspace,session,workspace,"time-original",HCIV2_FINAL)||
    hc_autosave_target_prepare(&seed->backup,runtime->workspace,geteuid(),nonce,seed->backup_path,"time-original")||
    hc_autosave_target_write(&seed->backup,seed->backup_path,seed->original,seed->original_length))return -2;
 seed->backup_retained=1;
 if(hc_stock_time_seed_backup_recheck(seed,game,runtime)||hc_stock_time_seed_recheck(seed,game,seed->runtime,seed->menu,seed->parent))return -2;
#ifdef HC_STOCK_MANAGER_TEST_HOOK
 {extern void hc_test_manager_image_hook(int);hc_test_manager_image_hook(6);}
#endif
 return 0;
}
int hc_stock_time_seed_close(HCStockTimeSeed *seed){
 if(!seed||!seed->ready||seed->fd<3){errno=EINVAL;return -1;}
 if(seed->backup.ready&&hc_autosave_target_close(&seed->backup))return -1;
 /* Caller excludes concurrent descriptor reuse during close and retry. */
 int fd=seed->fd;seed->fd=-1;
#ifdef HC_STOCK_MANAGER_TEST_HOOK
 extern int hc_test_time_seed_close(int);int result=hc_test_time_seed_close(fd);
#else
 int result=close(fd);
#endif
 if(result){
  int saved=errno?errno:EIO;errno=0;
  if(fcntl(fd,F_GETFD)!=-1||errno!=EBADF)seed->fd=fd;
  else *seed=(HCStockTimeSeed)HC_STOCK_TIME_SEED_INITIALIZER;
  errno=saved;return -1;
 }
 *seed=(HCStockTimeSeed)HC_STOCK_TIME_SEED_INITIALIZER;return 0;
}
int hc_stock_manager_image_publish(HCStockManagerImage *out,HCStockRetainedImage *retained,HCStockGameSession *game,HCStockControlSession *control,HCStockScreenshotReceipt *capture,HCConsoleRuntime *runtime,HCConsoleGame *menu,int manager_parent){
 struct stat manager,save,named;HCSessionExpected regions[6];size_t region_count=4;char time_path[1024],load_path[1024];HCScreenshotSessionNames names;HCNonceSequence sequence=HC_NONCE_SEQUENCE_INITIALIZER;uint8_t nonce[16];
 if(!out||out->attempted||out->published||out->target.ready||manager_parent<3||session_matches(retained,game,control,capture,runtime,menu)||
    image_path(menu->command.checkpoint.image,out->path)||hc_screenshot_session_names(game->token,&names)){errno=EINVAL;return -1;}
 const char *base=strrchr(out->path,'/');int flags=fcntl(manager_parent,F_GETFD);
 if(!base||!base[1]||flags<0||!(flags&FD_CLOEXEC)||fstat(manager_parent,&manager)||fstat(retained->target.parent,&save)||
    !S_ISDIR(manager.st_mode)||manager.st_uid!=geteuid()||(manager.st_mode&0777)!=0700||
    (manager.st_dev==save.st_dev&&manager.st_ino==save.st_ino)){errno=EINVAL;return -1;}
 regions[0]=(HCSessionExpected){retained->target.parent,game->save.identity,0};regions[1]=(HCSessionExpected){retained->target.parent,retained->clock,1};
 regions[2]=(HCSessionExpected){retained->target.parent,retained->image,100};regions[3]=(HCSessionExpected){manager_parent,out->path,103};
 /* If the same menu request also saves time, include that region in the
  * binding before either journal is created. Inventory otherwise rejects the
  * legitimate second intent in this shared parent as an unknown file. The
  * pinned parent must resolve both paths; separate parents require a future
  * caller to provide and authenticate a second descriptor. */
 if(menu->command.time.have_save){
  if(image_path(menu->command.time.save,time_path))return -1;
  regions[region_count++]=(HCSessionExpected){manager_parent,time_path,104};
 }
 if(menu->command.time.have_load){
  if(image_path(menu->command.time.load,load_path))return -1;
  if(!menu->command.time.have_save||!same_ascii_path(load_path,time_path))regions[region_count++]=(HCSessionExpected){manager_parent,load_path,105};
 }
 if(hc_session_validate_regions(regions,region_count)||!fstatat(manager_parent,base+1,&named,AT_SYMLINK_NOFOLLOW)||errno!=ENOENT){errno=EINVAL;return -1;}
 if(hc_nonce_sequence_init(&sequence))return -1;
 int r=hc_nonce_sequence_next(&sequence,nonce),saved=errno;if(hc_nonce_sequence_destroy(&sequence)&&!r){r=-1;saved=errno;}if(r){errno=saved;return -1;}
 char session[33],workspace[44];static const char hex[]="0123456789abcdef";memcpy(workspace,"checkpoint-",11);
 for(size_t i=0;i<16;i++){session[2*i]=hex[game->token[i]>>4];session[2*i+1]=hex[game->token[i]&15];workspace[11+2*i]=hex[nonce[i]>>4];workspace[12+2*i]=hex[nonce[i]&15];}session[32]=0;workspace[43]=0;
 if(!memcmp(nonce,game->token,16)||!strcmp(workspace,retained->target.workspace_name)){errno=EINVAL;return -1;}
 out->attempted=1;memcpy(out->binding,names.manager,sizeof out->binding);
 if(hc_binding_create(retained->target.parent,out->binding,game->game,game->rom.sha256,game->token,game->epoch,regions,region_count))return -2;
#ifdef HC_STOCK_MANAGER_TEST_HOOK
 {extern void hc_test_manager_image_hook(int);hc_test_manager_image_hook(1);}
#endif
 if(hciv2_create(manager_parent,session,workspace,base+1,HCIV2_FINAL))return -2;
#ifdef HC_STOCK_MANAGER_TEST_HOOK
 {extern void hc_test_manager_image_hook(int);hc_test_manager_image_hook(2);}
#endif
 if(hc_autosave_target_prepare(&out->target,manager_parent,geteuid(),nonce,out->path,base+1)||
    hc_autosave_target_write(&out->target,out->path,capture->image,capture->image_length))return -2;
#ifdef HC_STOCK_MANAGER_TEST_HOOK
 {extern void hc_test_manager_image_hook(int);hc_test_manager_image_hook(3);}
#endif
 if(session_matches(retained,game,control,capture,runtime,menu))return -2;
 out->published=1;return 0;
}
int hc_stock_manager_image_close(HCStockManagerImage *out){
 if(!out||!out->attempted){errno=EINVAL;return -1;}
 if(out->target.ready&&hc_autosave_target_close(&out->target))return -1;
 out->published=0;return 0;
}

/* Recheck the actual menu image against the authenticated capture. Caller
 * continues to hold and exclusively control the parent across the operation. */
static int manager_image_matches(int parent,const char *path,const HCStockScreenshotReceipt *capture){
 const char *base=strrchr(path,'/');struct stat before,after,named;int fd=-1,ok=0;
 if(!base||!base[1]||!capture||!capture->image||!capture->image_length){errno=EINVAL;return -1;}
 fd=openat(parent,base+1,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return -1;
 if(fstat(fd,&before)||fstatat(parent,base+1,&named,AT_SYMLINK_NOFOLLOW)||!S_ISREG(before.st_mode)||before.st_uid!=geteuid()||
    (before.st_mode&0777)!=0600||before.st_nlink!=1||before.st_size!=(off_t)capture->image_length||before.st_dev!=named.st_dev||before.st_ino!=named.st_ino)goto done;
 unsigned char buf[4096];
 for(size_t pos=0;pos<capture->image_length;){size_t wanted=capture->image_length-pos;if(wanted>sizeof buf)wanted=sizeof buf;
  ssize_t n=pread(fd,buf,wanted,(off_t)pos);if(n<0&&errno==EINTR)continue;if(n<=0||memcmp(buf,capture->image+pos,(size_t)n))goto done;pos+=(size_t)n;}
 if(fstat(fd,&after)||fstatat(parent,base+1,&named,AT_SYMLINK_NOFOLLOW)||before.st_dev!=after.st_dev||before.st_ino!=after.st_ino||
    before.st_size!=after.st_size||before.st_mode!=after.st_mode||before.st_nlink!=after.st_nlink||before.st_dev!=named.st_dev||before.st_ino!=named.st_ino)goto done;
 ok=1;
done: {int saved=errno;if(close(fd))ok=0;if(!ok){errno=saved?saved:EIO;return -1;}return 0;}
}

/* In a same-path update, publication intentionally moves the old inode to
 * the checkpoint workspace. Compare that inode and its exact original bytes
 * after the rename; its ctime may legitimately change during hard-linking. */
static int seed_previous_matches(HCStockTimeSeed *seed,HCAutosaveTarget *target){
 struct stat before,after,named;unsigned char bytes[21];uint64_t value=0;
 if(!seed||!seed->ready||!seed->same_target||!target||!target->ready||!target->consumed||target->workspace<3||
    !seed->original_length||seed->original_length>sizeof bytes||fstat(seed->fd,&before)||
    fstatat(target->workspace,"previous",&named,AT_SYMLINK_NOFOLLOW)||!S_ISREG(before.st_mode)||before.st_uid!=geteuid()||
    (before.st_mode&0022)||before.st_mode!=seed->snapshot.st_mode||before.st_uid!=seed->snapshot.st_uid||before.st_nlink!=1||before.st_dev!=seed->snapshot.st_dev||before.st_ino!=seed->snapshot.st_ino||
    before.st_size!=(off_t)seed->original_length||!same_seed_stat(&before,&named)||hc_playtime_read(seed->fd,&value)||value!=seed->prior||
    read_exact_time(seed->fd,bytes,seed->original_length)||memcmp(bytes,seed->original,seed->original_length)||
    fstat(seed->fd,&after)||!same_seed_stat(&before,&after)||fstatat(target->workspace,"previous",&named,AT_SYMLINK_NOFOLLOW)||!same_seed_stat(&before,&named)){errno=EIO;return -1;}
 return 0;
}

static int publish_time(HCStockManagerTime *out,HCStockManagerImage *image,HCStockRetainedImage *retained,HCStockGameSession *game,HCStockControlSession *control,HCStockScreenshotReceipt *capture,HCConsoleRuntime *runtime,HCConsoleGame *menu,HCStockTimeSeed *seed,int parent,HCPlaytimeInstant start,HCPlaytimeInstant end){
 HCScreenshotSessionNames names;HCSessionExpected regions[6];HCIV2Entry entries[16];size_t count=0,length=0,region_count=5;char text[20],expected_image[1024];uint64_t value,prior=seed?seed->prior:0;
 struct stat named,parent_stat,image_parent;HCNonceSequence sequence=HC_NONCE_SEQUENCE_INITIALIZER;uint8_t nonce[16];
 if(!out||out->attempted||out->published||out->target.ready||!image||!image->published||!image->target.ready||!image->target.consumed||parent<3||
    !menu||!menu->command.time.have_save||!!menu->command.time.have_load!=!!seed||session_matches(retained,game,control,capture,runtime,menu)||
    (seed&&(hc_stock_time_seed_recheck(seed,game,runtime,menu,parent)||hc_stock_time_seed_backup_recheck(seed,game,seed->backup_runtime)))||
    hc_screenshot_session_names(game->token,&names)||strcmp(image->binding,names.manager)||image_path(menu->command.checkpoint.image,expected_image)||
    strcmp(image->path,expected_image)||image_path(menu->command.time.save,out->path)||hc_playtime_accumulate(prior,start,end,&value)||hc_playtime_format(value,text,sizeof text,&length)||
    fstat(parent,&parent_stat)||fstat(image->target.parent,&image_parent)||parent_stat.st_dev!=image_parent.st_dev||parent_stat.st_ino!=image_parent.st_ino){errno=EINVAL;return -1;}
 const char *base=strrchr(out->path,'/');const char *image_base=strrchr(image->path,'/');int flags=fcntl(parent,F_GETFD);
 if(!base||!base[1]||!image_base||!image_base[1]||flags<0||!(flags&FD_CLOEXEC)||!S_ISDIR(parent_stat.st_mode)||parent_stat.st_uid!=geteuid()||(parent_stat.st_mode&0777)!=0700){errno=EINVAL;return -1;}
 regions[0]=(HCSessionExpected){retained->target.parent,game->save.identity,0};regions[1]=(HCSessionExpected){retained->target.parent,retained->clock,1};
 regions[2]=(HCSessionExpected){retained->target.parent,retained->image,100};regions[3]=(HCSessionExpected){parent,image->path,103};regions[4]=(HCSessionExpected){parent,out->path,104};
 if(seed&&!seed->same_target)regions[region_count++]=(HCSessionExpected){parent,seed->path,105};
 if(hc_session_validate_regions(regions,region_count)||
    (seed&&seed->same_target?(fstatat(parent,base+1,&named,AT_SYMLINK_NOFOLLOW)||!same_seed_stat(&seed->snapshot,&named)):(!fstatat(parent,base+1,&named,AT_SYMLINK_NOFOLLOW)||errno!=ENOENT))||
    manager_image_matches(parent,image->path,capture)||hc_binding_inventory(retained->target.parent,image->binding,game->game,game->rom.sha256,game->token,game->epoch,regions,region_count,3,entries,16,&count)||
    count!=1||strcmp(entries[0].region,image_base+1)||strcmp(entries[0].workspace,image->target.workspace_name)||entries[0].kind!=HCIV2_FINAL||!entries[0].workspace_present){errno=EINVAL;return -1;}
 if(hc_nonce_sequence_init(&sequence))return -1;
 int r=hc_nonce_sequence_next(&sequence,nonce),saved=errno;if(hc_nonce_sequence_destroy(&sequence)&&!r){r=-1;saved=errno;}if(r){errno=saved;return -1;}
 char session[33],workspace[44];static const char hex[]="0123456789abcdef";memcpy(workspace,"checkpoint-",11);
 for(size_t i=0;i<16;i++){session[2*i]=hex[game->token[i]>>4];session[2*i+1]=hex[game->token[i]&15];workspace[11+2*i]=hex[nonce[i]>>4];workspace[12+2*i]=hex[nonce[i]&15];}session[32]=0;workspace[43]=0;
 if(!memcmp(nonce,game->token,16)||!strcmp(workspace,image->target.workspace_name)){errno=EINVAL;return -1;}
 out->attempted=1;
 if(hciv2_create(parent,session,workspace,base+1,HCIV2_FINAL))return -2;
#ifdef HC_STOCK_MANAGER_TEST_HOOK
 {extern void hc_test_manager_image_hook(int);hc_test_manager_image_hook(4);}
#endif
 if(hc_autosave_target_prepare(&out->target,parent,geteuid(),nonce,out->path,base+1)||hc_autosave_target_write(&out->target,out->path,text,length))return -2;
#ifdef HC_STOCK_MANAGER_TEST_HOOK
 {extern void hc_test_manager_image_hook(int);hc_test_manager_image_hook(5);}
#endif
 if(session_matches(retained,game,control,capture,runtime,menu)||(seed&&(hc_stock_time_seed_backup_recheck(seed,game,seed->backup_runtime)||(seed->same_target?seed_previous_matches(seed,&out->target):hc_stock_time_seed_recheck(seed,game,runtime,menu,parent))))||manager_image_matches(parent,image->path,capture)||
    hc_binding_inventory(retained->target.parent,image->binding,game->game,game->rom.sha256,game->token,game->epoch,regions,region_count,4,entries,16,&count)||count!=2)return -2;
 int fd=openat(parent,base+1,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);uint64_t actual=0;struct stat held;
 if(fd<0)return -2;
 int bad=fstat(fd,&held)||fstatat(parent,base+1,&named,AT_SYMLINK_NOFOLLOW)||held.st_dev!=named.st_dev||held.st_ino!=named.st_ino||hc_playtime_read(fd,&actual)||actual!=value;
 if(close(fd))bad=1;if(bad){errno=EIO;return -2;}
 out->published=1;return 0;
}
int hc_stock_manager_time_publish(HCStockManagerTime *out,HCStockManagerImage *image,HCStockRetainedImage *retained,HCStockGameSession *game,HCStockControlSession *control,HCStockScreenshotReceipt *capture,HCConsoleRuntime *runtime,HCConsoleGame *menu,int parent,HCPlaytimeInstant start,HCPlaytimeInstant end){
 return publish_time(out,image,retained,game,control,capture,runtime,menu,NULL,parent,start,end);
}
int hc_stock_manager_time_publish_resumed(HCStockManagerTime *out,HCStockManagerImage *image,HCStockRetainedImage *retained,HCStockGameSession *game,HCStockControlSession *control,HCStockScreenshotReceipt *capture,HCConsoleRuntime *runtime,HCConsoleGame *menu,HCStockTimeSeed *seed,int parent,HCPlaytimeInstant start,HCPlaytimeInstant end){
 if(!seed){errno=EINVAL;return -1;}return publish_time(out,image,retained,game,control,capture,runtime,menu,seed,parent,start,end);
}
int hc_stock_manager_time_close(HCStockManagerTime *out){
 if(!out||!out->attempted){errno=EINVAL;return -1;}
 if(out->target.ready&&hc_autosave_target_close(&out->target))return -1;
 out->published=0;return 0;
}
