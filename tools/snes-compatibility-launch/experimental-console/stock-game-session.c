#define _POSIX_C_SOURCE 200809L
#include "stock-game-session.h"
#include "recovery-binding.h"
#include "save-directory-lock.h"
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static int stock_game_prepare(HCStockGameSession *s,HCConsoleGame *game,int argc,const char *const argv[],const char *profiles,int parent,int stage,const char *stage_name,size_t stage_size,const char *binding,const uint8_t token[16],uint64_t epoch,const uint8_t nonce[16],int existing_lock){
 HCCompatibilityMenuCommand parsed;HCGameSavePaths paths;
 if(!s||s->save_lock!=-1||s->rom.ready||s->save.phase!=HC_STOCK_EMPTY||!game||!game->rom.ready||!argv||!profiles||!binding||strnlen(binding,sizeof s->binding)>=sizeof s->binding||!token||
    hc_parse_compatibility_menu_command(argc,argv,&parsed)||strcmp(parsed.game,game->command.game)||strcmp(parsed.rom_name,game->command.rom_name)||
    strcmp(parsed.digest,game->rom.sha256)||strcmp(parsed.rom_name,game->rom.name)||
    parsed.manager.present!=game->command.manager.present||parsed.manager.wait_fd!=game->command.manager.wait_fd||
    parsed.manager.start_fd!=game->command.manager.start_fd||parsed.manager.finish_fd!=game->command.manager.finish_fd||
    hc_launch_isolated_save_paths_at_root(argc-4,argv+4,parsed.game,parsed.digest,profiles,&paths)||hc_verified_launch_recheck(&game->rom)){errno=EINVAL;return -1;}
 for(unsigned i=0;i<HC_OPTION_COUNT;i++)if((parsed.manager.present&(1u<<i))&&strcmp(parsed.manager.values[i],game->command.manager.values[i])){errno=EINVAL;return -1;}
 if(hc_stock_save_validate_stage(stage,parent,stage_name,stage_size))return -1;
 s->save_lock=existing_lock<0?hc_save_directory_lock(parent,geteuid()):hc_save_directory_borrow_lock(parent,existing_lock,geteuid());if(s->save_lock<0)return -1;
 /* Reopen by trusted parent and digest; retain our own independently checked
  * descriptor. The caller still excludes mutation and authenticates roots. */
 if(hc_verified_rom_open(&s->rom,game->rom.parent,game->rom.name,geteuid(),game->rom.sha256))return -1;
 if(s->rom.snapshot.st_dev!=game->rom.snapshot.st_dev||s->rom.snapshot.st_ino!=game->rom.snapshot.st_ino||hc_verified_launch_recheck(&game->rom)||hc_verified_launch_recheck(&s->rom)){errno=EIO;return -1;}
 if(hc_stock_save_prepare_pair(&s->save,parent,binding,parsed.game,parsed.digest,token,epoch,nonce,paths.sram,paths.rtc)||
    hc_stock_save_bind_stage(&s->save,stage,stage_name,stage_size))return -1;
 s->save.cooperative_lock=s->save_lock;
 if(hc_verified_launch_recheck(&s->rom)){s->fault=1;s->save.phase=HC_STOCK_FAILED;errno=EIO;return -1;}
 memcpy(s->game,parsed.game,sizeof s->game);memcpy(s->binding,binding,strlen(binding)+1);memcpy(s->token,token,sizeof s->token);s->epoch=epoch;return 0;
}
int hc_stock_game_prepare(HCStockGameSession *s,HCConsoleGame *game,int argc,const char *const argv[],const char *profiles,int parent,int stage,const char *name,size_t size,const char *binding,const uint8_t token[16],uint64_t epoch,const uint8_t nonce[16]){
 return stock_game_prepare(s,game,argc,argv,profiles,parent,stage,name,size,binding,token,epoch,nonce,-1);
}
int hc_stock_game_prepare_with_lock(HCStockGameSession *s,HCConsoleGame *game,int argc,const char *const argv[],const char *profiles,int parent,int stage,const char *name,size_t size,const char *binding,const uint8_t token[16],uint64_t epoch,const uint8_t nonce[16],int held_lock){
 if(held_lock<3){errno=EINVAL;return -1;}
 return stock_game_prepare(s,game,argc,argv,profiles,parent,stage,name,size,binding,token,epoch,nonce,held_lock);
}
int hc_stock_game_recheck(HCStockGameSession *s){
 struct stat stage,parent,locked;
 if(!s){errno=EINVAL;return -1;}
 if(s->fault||s->save_lock<0||!s->rom.ready||!s->save.target.ready||s->save.stage_dir<0||
    (s->save.phase!=HC_STOCK_PREPARED&&s->save.phase!=HC_STOCK_RUNNING&&s->save.phase!=HC_STOCK_REAPED_CLEAN&&s->save.phase!=HC_STOCK_REAPED_NO_SRAM&&s->save.phase!=HC_STOCK_PUBLISHED)||
    fstat(s->save.stage_dir,&stage)||!S_ISDIR(stage.st_mode)||stage.st_uid!=geteuid()||(stage.st_mode&0777)!=0700||
    fstat(s->save.target.parent,&parent)||!S_ISDIR(parent.st_mode)||parent.st_uid!=geteuid()||(parent.st_mode&0777)!=0700||
    fstat(s->save_lock,&locked)||locked.st_dev!=parent.st_dev||locked.st_ino!=parent.st_ino||hc_verified_launch_recheck(&s->rom)){
  /* Do not prevent an already-running child from being polled and reaped. */
  s->fault=1;if(s->save.phase==HC_STOCK_PREPARED||s->save.phase==HC_STOCK_REAPED_CLEAN||s->save.phase==HC_STOCK_REAPED_NO_SRAM)s->save.phase=HC_STOCK_FAILED;
  errno=EINVAL;return -1;
 }
 return 0;
}
static int same_autoload(const struct stat *a,const struct stat *b){
 if(a->st_dev!=b->st_dev||a->st_ino!=b->st_ino||a->st_uid!=b->st_uid||a->st_mode!=b->st_mode||a->st_nlink!=b->st_nlink||a->st_size!=b->st_size)return 0;
#ifdef __APPLE__
 return a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec&&a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec&&a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec&&a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec;
#else
 return a->st_mtim.tv_sec==b->st_mtim.tv_sec&&a->st_mtim.tv_nsec==b->st_mtim.tv_nsec&&a->st_ctim.tv_sec==b->st_ctim.tv_sec&&a->st_ctim.tv_nsec==b->st_ctim.tv_nsec;
#endif
}
int hc_stock_game_autoload_ready(HCStockGameSession *s,int autoload){
 if(!s||(autoload!=0&&autoload!=1)||s->save.phase!=HC_STOCK_PREPARED||hc_stock_game_recheck(s)){errno=EINVAL;return -1;}
 if(!autoload){if(s->autoload_bytes||s->autoload_length){errno=EINVAL;return -1;}return 0;}
 if(!s->autoload_bytes||!s->autoload_length||s->autoload_length>16u*1024u*1024u){errno=EINVAL;return -1;}
 int fd=openat(s->save.stage_dir,"210.state.auto",O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return -1;
 struct stat held,named,after;unsigned char bytes[4096];int ok=0;
 if(fstat(fd,&held)||!S_ISREG(held.st_mode)||!same_autoload(&s->autoload_snapshot,&held))goto done;
 for(size_t pos=0;pos<s->autoload_length;){size_t part=s->autoload_length-pos;if(part>sizeof bytes)part=sizeof bytes;
  ssize_t n=pread(fd,bytes,part,(off_t)pos);if(n<0&&errno==EINTR)continue;if(n<=0||memcmp(bytes,s->autoload_bytes+pos,(size_t)n))goto done;pos+=(size_t)n;}
 if(fstat(fd,&after)||fstatat(s->save.stage_dir,"210.state.auto",&named,AT_SYMLINK_NOFOLLOW)||!same_autoload(&held,&after)||!same_autoload(&held,&named))goto done;
 ok=1;
done: {int saved=errno;if(close(fd))ok=0;if(!ok){errno=saved?saved:EIO;return -1;}return 0;}
}
int hc_stock_game_seed_stage(HCStockGameSession *s){
 if(hc_stock_game_recheck(s))return -1;
 return hc_stock_save_seed_stage(&s->save);
}
int hc_stock_game_start_rom(HCStockGameSession *s,int target,const char *program,char *const argv[],char *const envp[]){
 if(hc_stock_game_recheck(s))return -1;
 /* A measured size is bound to a reviewed core, so an unreviewed launch
  * cannot safely use this prepared session. */
 if(s->detected_core_sha[0]){errno=EINVAL;return -1;}
 int r=hc_stock_save_start_rom(&s->save,&s->rom,target,program,argv,envp);
 if(r&&s->save.rom_fault)s->fault=1;return r;
}
int hc_stock_game_start_reviewed(HCStockGameSession *s,int target,HCVerifiedLaunch *program,const char *program_path,HCVerifiedLaunch *core,const char *core_path,HCVerifiedLaunch *config,const char *config_path,int autoload,char *const envp[]){
 if((autoload&&target!=210)||hc_stock_game_autoload_ready(s,autoload))return -1;
 if(s->detected_core_sha[0]&&(!core||strcmp(s->detected_core_sha,core->sha256))){errno=EINVAL;return -1;}
 int r=hc_stock_save_start_reviewed(&s->save,&s->rom,target,program,program_path,core,core_path,config,config_path,autoload,envp);
 if(r&&s->save.rom_fault)s->fault=1;return r;
}
int hc_stock_game_start_seeded_reviewed(HCStockGameSession *s,int target,HCVerifiedLaunch *program,const char *program_path,HCVerifiedLaunch *core,const char *core_path,HCVerifiedLaunch *config,const char *config_path,int autoload,char *const envp[]){
 if(!s||(s->detected_core_sha[0]&&(!core||strcmp(s->detected_core_sha,core->sha256)))){errno=EINVAL;return -1;}
 if((autoload&&target!=210)||hc_stock_game_autoload_ready(s,autoload)||hc_stock_save_preflight_reviewed(&s->save,&s->rom,target,program,program_path,core,core_path,config,config_path,autoload,envp))return -1;
 if(hc_stock_game_seed_stage(s)<0)return -1;
 return hc_stock_game_start_reviewed(s,target,program,program_path,core,core_path,config,config_path,autoload,envp);
}
int hc_stock_game_validate_no_sram(HCStockGameSession *s){
 if(!s||(s->detected_core_sha[0]&&!s->detected_no_sram)){errno=EINVAL;return -1;}
 if(hc_stock_game_recheck(s))return -1;
 return hc_stock_save_validate_no_sram(&s->save);
}
static int stock_regions(HCStockGameSession *s,HCSessionExpected regions[2],char clock[1024]){
 size_t n=strnlen(s->save.identity,sizeof s->save.identity);
 if(n<12||n>=sizeof s->save.identity||strcmp(s->save.identity+n-12,"/battery.srm")){errno=EINVAL;return -1;}
 memcpy(clock,s->save.identity,n+1);memcpy(clock+n-3,"rtc",3);
 regions[0]=(HCSessionExpected){s->save.target.parent,s->save.identity,0};
 regions[1]=(HCSessionExpected){s->save.target.parent,clock,1};return 0;
}
int hc_stock_game_finish_no_sram(HCStockGameSession *s,const void *expected,size_t length){
 if(hc_stock_game_validate_no_sram(s))return -1;
 if(((expected==NULL)!=(length==0))||(length&&length!=s->save.stage_size)||!s->save.initial_valid||
    (!!expected!=!!s->save.initial_present)||
    (expected&&(!s->save.initial_bytes||s->save.initial_length!=length||memcmp(s->save.initial_bytes,expected,length)))){errno=EINVAL;return -1;}
 /* The caller may pass session-owned bytes: retain a private copy before
  * closing the save owner and releasing its snapshot. */
 unsigned char *copy=NULL;if(length){copy=malloc(length);if(!copy)return -1;memcpy(copy,expected,length);}
 int parent=s->save.target.parent;char workspace[44];memcpy(workspace,s->save.target.workspace_name,sizeof workspace);
 HCSessionExpected regions[2];char clock[1024];if(stock_regions(s,regions,clock)){free(copy);return -1;}
 int result=hc_binding_finish_unpublished(parent,s->binding,s->game,s->rom.sha256,s->token,s->epoch,regions,2,0,workspace,copy,length);int saved=errno;
 free(copy);
 /* A refusal or partial cleanup retains the owner and snapshot for a
  * supervised retry. The helper validates the journal on every attempt. */
 if(result){errno=saved;return result;}
 if(hc_stock_save_close(&s->save)){s->fault=1;errno=EIO;return -2;}
 s->finalized=1;
 return 0;
}
int hc_stock_game_finish_no_sram_captured(HCStockGameSession *s){
 if(!s||!s->save.initial_valid){errno=EINVAL;return -1;}
 if(s->save.initial_present){
  if(!s->save.initial_bytes||!s->save.initial_length||s->save.initial_length!=s->save.stage_size){errno=EINVAL;return -1;}
  return hc_stock_game_finish_no_sram(s,s->save.initial_bytes,s->save.initial_length);
 }
 if(s->save.initial_bytes||s->save.initial_length){errno=EINVAL;return -1;}
 return hc_stock_game_finish_no_sram(s,NULL,0);
}
int hc_stock_game_finish_no_sram_after_exit(HCStockGameSession *s,HCStockControlSession *control){
 if(!s||!control||control->save!=&s->save||control->exit_owner.save!=&s->save||
    !control->started||!control->finished||control->failed||control->exit_owner.phase!=2||
    (control->reason!=HC_STOCK_CONTROL_RESET&&control->reason!=HC_STOCK_CONTROL_POWER)||
    control->exit_owner.timed_out||control->exit_owner.kill_sent||s->save.child.pid!=-1||s->save.child.input!=-1||
    s->save.phase!=HC_STOCK_REAPED_NO_SRAM){errno=EINVAL;return -1;}
 if(hc_stock_control_refresh_finished(control))return -1;
 return hc_stock_game_finish_no_sram_captured(s);
}
/* Verify the live target is still the save observed when this session began.
 * Caller must exclude concurrent writers through publication; this is not a
 * lock and cannot replace the durable evidence required after a crash. */
static int initial_target_unchanged(HCStockSaveSession *s){
 struct stat named,held,after;int fd=-1,ok=0;unsigned char buf[4096];size_t pos=0;
 if(!s->initial_valid){errno=EINVAL;return -1;}
 if(!s->initial_present){if(fstatat(s->target.parent,s->target.destination,&named,AT_SYMLINK_NOFOLLOW)==0){errno=EEXIST;return -1;}return errno==ENOENT?0:-1;}
 if(!s->initial_bytes||s->initial_length!=s->stage_size){errno=EINVAL;return -1;}
 fd=openat(s->target.parent,s->target.destination,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return -1;
 if(fstat(fd,&held)||!S_ISREG(held.st_mode)||held.st_uid!=geteuid()||held.st_nlink!=1||(held.st_mode&0022)||held.st_size!=(off_t)s->initial_length||
    fstatat(s->target.parent,s->target.destination,&named,AT_SYMLINK_NOFOLLOW)||held.st_dev!=named.st_dev||held.st_ino!=named.st_ino)goto done;
 while(pos<s->initial_length){size_t n=s->initial_length-pos;if(n>sizeof buf)n=sizeof buf;ssize_t got=pread(fd,buf,n,(off_t)pos);if(got<0&&errno==EINTR)continue;if(got<=0||memcmp(buf,s->initial_bytes+pos,(size_t)got))goto done;pos+=(size_t)got;}
 if(fstat(fd,&after)||after.st_dev!=held.st_dev||after.st_ino!=held.st_ino||after.st_size!=held.st_size||after.st_nlink!=1||
    fstatat(s->target.parent,s->target.destination,&named,AT_SYMLINK_NOFOLLOW)||named.st_dev!=held.st_dev||named.st_ino!=held.st_ino)goto done;
 ok=1;
 done: if(close(fd))ok=0;if(!ok){errno=EIO;return -1;}return 0;
}
int hc_stock_game_publish_stage(HCStockGameSession *s){
 if(!s||s->detected_no_sram){errno=EINVAL;return -1;}
 if(hc_stock_game_recheck(s)||initial_target_unchanged(&s->save))return -1;
 return hc_stock_save_publish_stage(&s->save);
}
int hc_stock_game_publish_after_exit(HCStockGameSession *s,HCStockControlSession *control){
 if(!s||!control||control->save!=&s->save||control->exit_owner.save!=&s->save||
    !control->started||!control->finished||control->failed||control->exit_owner.phase!=2||
    (control->reason!=HC_STOCK_CONTROL_RESET&&control->reason!=HC_STOCK_CONTROL_POWER)||
    control->exit_owner.timed_out||control->exit_owner.kill_sent||s->save.child.pid!=-1||s->save.child.input!=-1||
    s->save.phase!=HC_STOCK_REAPED_CLEAN){errno=EINVAL;return -1;}
 if(hc_stock_control_refresh_finished(control))return -1;
 return hc_stock_game_publish_stage(s);
}
int hc_stock_game_finish_published(HCStockGameSession *s,const void *current,size_t current_len,const void *previous,size_t previous_len){
 if(!s||s->save.phase!=HC_STOCK_PUBLISHED||!current||current_len!=s->save.stage_size||((previous==NULL)!=(previous_len==0))||(previous&&previous_len!=s->save.stage_size)){errno=EINVAL;return -1;}
 if(hc_stock_game_recheck(s))return -1;
 /* Retained snapshot is a second check, not a durable backup. A caller must
  * still independently authenticate and retain the prior state. */
 if(!s->save.initial_valid||!!previous!=!!s->save.initial_present||
    (previous&&(!s->save.initial_bytes||s->save.initial_length!=previous_len||memcmp(s->save.initial_bytes,previous,previous_len)))){errno=EINVAL;return -1;}
 int parent=s->save.target.parent;HCSessionExpected regions[2];char clock[1024];if(stock_regions(s,regions,clock))return -1;
 int result=hc_binding_finish_published(parent,s->binding,s->game,s->rom.sha256,s->token,s->epoch,regions,2,0,s->save.target.workspace_name,current,current_len,previous,previous_len);
 if(!result)s->finalized=1;return result;
}
int hc_stock_game_finish_published_captured(HCStockGameSession *s,const void *previous,size_t previous_len){
 if(!s||s->save.phase!=HC_STOCK_PUBLISHED||!s->save.published_bytes||s->save.published_length!=s->save.stage_size){errno=EINVAL;return -1;}
 return hc_stock_game_finish_published(s,s->save.published_bytes,s->save.published_length,previous,previous_len);
}
int hc_stock_game_finish_published_after_exit(HCStockGameSession *s,HCStockControlSession *control,const void *previous,size_t previous_len){
 if(!s||!control||control->save!=&s->save||s->save.phase!=HC_STOCK_PUBLISHED||
    s->save.child.pid!=-1||s->save.child.input!=-1){errno=EINVAL;return -1;}
 if(hc_stock_control_refresh_finished(control))return -1;
 return hc_stock_game_finish_published_captured(s,previous,previous_len);
}
int hc_stock_game_close(HCStockGameSession *s){
 if(!s){errno=EINVAL;return -1;}
 if(s->save.phase!=HC_STOCK_EMPTY&&s->save.phase!=HC_STOCK_CLOSED&&hc_stock_save_close(&s->save))return -1;
 if(s->rom.ready&&hc_verified_launch_close(&s->rom))return -1;
 if(s->save_lock>=0){
  int fd=s->save_lock;s->save_lock=-1;
  if(close(fd)){
   int saved=errno;errno=0;
   if(fcntl(fd,F_GETFD)!=-1||errno!=EBADF)s->save_lock=fd;
   errno=saved?saved:EIO;return -1;
  }
 }
 free(s->autoload_bytes);s->autoload_bytes=NULL;s->autoload_length=0;memset(&s->autoload_snapshot,0,sizeof s->autoload_snapshot);
 return 0;
}
