#define _POSIX_C_SOURCE 200809L
#include "console-runtime.h"
#include "nonce-sequence.h"
#include "owned_directory.h"
#include "control_pipe.h"
#include "startup-monitor-experimental.h"
#include "stock-runtime-bridge.h"
#include "save-directory-lock.h"
#include "periodic-owner.h"
#include "isolated_saves.h"
#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <string.h>
#include <unistd.h>

int hc_console_runtime_open_session_parent(int save,uid_t uid,int create){
 struct stat parent,before,held,after,named;int fd=-1,created=0;
 if((create!=0&&create!=1)||uid!=geteuid()||fstat(save,&parent)||!S_ISDIR(parent.st_mode)||parent.st_uid!=uid||(parent.st_mode&0777)!=0700){errno=EINVAL;return -1;}
 if(create){if(!mkdirat(save,"sessions",0700))created=1;else if(errno!=EEXIST)return -1;}
 if(fstatat(save,"sessions",&before,AT_SYMLINK_NOFOLLOW)||!S_ISDIR(before.st_mode)||before.st_uid!=uid||(before.st_mode&0777)!=0700)goto fail;
 fd=openat(save,"sessions",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)goto fail;
 if(fstat(fd,&held)||fstat(save,&after)||fstatat(save,"sessions",&named,AT_SYMLINK_NOFOLLOW)||
    !S_ISDIR(held.st_mode)||held.st_dev!=before.st_dev||held.st_ino!=before.st_ino||held.st_uid!=uid||held.st_mode!=before.st_mode||
    named.st_dev!=held.st_dev||named.st_ino!=held.st_ino||named.st_uid!=held.st_uid||named.st_mode!=held.st_mode||
    after.st_dev!=parent.st_dev||after.st_ino!=parent.st_ino||after.st_uid!=parent.st_uid||after.st_mode!=parent.st_mode)goto fail;
 if(created&&(fsync(fd)||fsync(save)))goto fail;
 return fd;
fail: {int saved=errno?errno:EIO;if(fd>=0)close(fd);errno=saved;return -1;}
}

/* Until completed sessions have durable, independently checked completion
 * evidence, a manager record by itself cannot distinguish a finished game
 * from a crash before the save intent was written.  Do not start another
 * game while any prior workspace remains.  The caller holds the save lock;
 * it must exclude non-cooperating writers for the duration of the check. */
static int require_empty_session_inventory(int parent){
 int fd=openat(parent,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
 if(fd<0)return -1;
 DIR *directory=fdopendir(fd);if(!directory){int saved=errno;close(fd);errno=saved;return -1;}
 int result=0,saved=0;size_t seen=0;
 for(;;){errno=0;struct dirent *entry=readdir(directory);if(!entry){if(errno){result=-1;saved=errno;}break;}
  if(++seen>8192){result=-1;saved=EOVERFLOW;break;}
  if(!strncmp(entry->d_name,"checkpoint-",11)){result=-1;saved=EBUSY;break;}
 }
 if(closedir(directory)){result=-1;if(!saved)saved=errno;}
 if(result)errno=saved?saved:EIO;
 return result;
}

int hc_console_runtime_prepare_bound(HCConsoleRuntime *r,int parent,uid_t uid,const HCLaunchRequest *reviewed,const char *game,const char *digest){
 unsigned char frame[HC_LAUNCH_REQUEST_SIZE];HCLaunchRequest request;
 if(!r||r->claimed||r->stock_claimed||r->save_lock!=-1||r->workspace!=-1||r->save!=-1||r->image!=-1||r->report[0]!=-1||r->report[1]!=-1||r->exitpipe[0]!=-1||r->exitpipe[1]!=-1||r->exit_pin!=-1||r->frontend.ready||r->workspace_name[0]||!reviewed||!game||!digest||uid!=geteuid()||strnlen(game,12)!=11||strnlen(digest,65)!=64){errno=EINVAL;return -1;}
 request=*reviewed;
 if(hc_launch_request_encode(&request,frame)||strcmp(request.game,game)||strcmp(request.digest,digest)){errno=EINVAL;return -1;}
 r->request=request;
 r->workspace=hc_create_checkpoint_workspace(parent,uid,request.session,r->workspace_name);
 if(r->workspace<0)return -1;
 if(fsync(parent))return -1;
 r->save=hc_create_checkpoint_file(r->workspace,uid,"state.tmp");if(r->save<0)return -1;
 r->image=hc_create_checkpoint_file(r->workspace,uid,"image.tmp");if(r->image<0)return -1;
 if(fsync(r->workspace)||hc_control_pipe(r->report)||hc_control_pipe(r->exitpipe))return -1;
 r->exit_pin=fcntl(r->exitpipe[0],F_DUPFD_CLOEXEC,3);if(r->exit_pin<0)return -1;
 return 0;
}
int hc_console_runtime_prepare(HCConsoleRuntime *r,int parent,uid_t uid,const char *game,const char *digest){
 HCNonceSequence nonce=HC_NONCE_SEQUENCE_INITIALIZER;HCLaunchRequest request={0};
 if(!game||!digest||strnlen(game,12)!=11||strnlen(digest,65)!=64){errno=EINVAL;return -1;}
 memcpy(request.game,game,12);memcpy(request.digest,digest,65);request.epoch=1;
 if(hc_nonce_sequence_init(&nonce))return -1;
 int result=hc_nonce_sequence_next(&nonce,request.session);int saved=errno;
 if(hc_nonce_sequence_destroy(&nonce)&&!result){result=-1;saved=errno;}
 if(result){errno=saved;return -1;}
 return hc_console_runtime_prepare_bound(r,parent,uid,&request,game,digest);
}
/* The entry and the held descriptor must still identify the same empty,
 * private file. The caller must continue to exclude concurrent replacement
 * through spawn and use; this check is not a lock or authentication. */
static int checked_output(int directory,int fd,const char *name){
 struct stat dir,held,entry;int flags=fcntl(fd,F_GETFL),fdflags=fcntl(fd,F_GETFD);
 return flags>=0&&fdflags>=0&&(flags&O_ACCMODE)==O_RDWR&&!(flags&O_APPEND)&&(fdflags&FD_CLOEXEC)&&
  !fstat(directory,&dir)&&S_ISDIR(dir.st_mode)&&dir.st_uid==geteuid()&&(dir.st_mode&0777)==0700&&
  !fstat(fd,&held)&&!fstatat(directory,name,&entry,AT_SYMLINK_NOFOLLOW)&&S_ISREG(held.st_mode)&&S_ISREG(entry.st_mode)&&
  held.st_uid==geteuid()&&held.st_nlink==1&&(held.st_mode&0777)==0600&&held.st_size==0&&held.st_dev==entry.st_dev&&held.st_ino==entry.st_ino;
}
static int discard_empty_workspace(HCConsoleRuntime *r,int parent,HCConsoleSupervisor *supervisor,int finalized){
 struct stat root,held,named;char name[44];unsigned char frame[HC_LAUNCH_REQUEST_SIZE];static const char hex[]="0123456789abcdef";int directory=-1,scanfd=-1,modified=0;DIR *scan=NULL;
 if(!r||!supervisor||r->attempted||(r->claimed&&!finalized)||r->supervisor||supervisor->phase!=HC_SUPERVISOR_EMPTY||supervisor->child.pid!=-1||supervisor->child.input!=-1||
    r->workspace<0||r->save<0||r->image<0||hc_launch_request_encode(&r->request,frame)||fstat(parent,&root)||!S_ISDIR(root.st_mode)||root.st_uid!=geteuid()||(root.st_mode&0777)!=0700||
    !checked_output(r->workspace,r->save,"state.tmp")||!checked_output(r->workspace,r->image,"image.tmp")){errno=EINVAL;return -1;}
 memcpy(name,"checkpoint-",11);for(size_t i=0;i<16;i++){name[11+2*i]=hex[r->request.session[i]>>4];name[12+2*i]=hex[r->request.session[i]&15];}name[43]=0;
 if(strcmp(name,r->workspace_name)||fstat(r->workspace,&held)||fstatat(parent,name,&named,AT_SYMLINK_NOFOLLOW)||!S_ISDIR(named.st_mode)||held.st_dev!=named.st_dev||held.st_ino!=named.st_ino||held.st_mode!=named.st_mode||held.st_uid!=named.st_uid){errno=EINVAL;return -1;}
 directory=fcntl(r->workspace,F_DUPFD_CLOEXEC,3);if(directory<0)return -1;
 scanfd=openat(directory,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(scanfd<0)goto fail;
 scan=fdopendir(scanfd);if(!scan)goto fail;scanfd=-1;int state=0,image=0,metadata=0;
 for(;;){errno=0;struct dirent *entry=readdir(scan);if(!entry){if(errno)goto fail;break;}
  if(!strcmp(entry->d_name,".")||!strcmp(entry->d_name,".."))continue;
  if(!strcmp(entry->d_name,"state.tmp")&&!state){state=1;continue;}
  if(!strcmp(entry->d_name,"image.tmp")&&!image){image=1;continue;}
  if(!strcmp(entry->d_name,"manager.meta")&&!metadata&&finalized){metadata=1;continue;}
  errno=EBUSY;goto fail;
 }
 if(closedir(scan)){scan=NULL;goto fail;}scan=NULL;
 HCManagerCheckpointPaths empty={0};
 if(!state||!image||(metadata&&hc_console_game_check_manager_record(directory,&r->request,&empty))||!checked_output(r->workspace,r->save,"state.tmp")||!checked_output(r->workspace,r->image,"image.tmp")||hc_console_runtime_close(r,supervisor))goto fail;
 if(metadata){if(hc_console_game_check_manager_record(directory,&r->request,&empty)||unlinkat(directory,"manager.meta",0))goto fail;modified=1;}
 if(unlinkat(directory,"state.tmp",0))goto fail;modified=1;
 if(unlinkat(directory,"image.tmp",0)||fsync(directory)||fstatat(parent,name,&named,AT_SYMLINK_NOFOLLOW)||!S_ISDIR(named.st_mode)||named.st_dev!=held.st_dev||named.st_ino!=held.st_ino||unlinkat(parent,name,AT_REMOVEDIR)||fsync(parent))goto fail;
 if(close(directory))return -2;return 0;
fail: {int saved=errno;if(scan)closedir(scan);if(scanfd>=0)close(scanfd);if(directory>=0)close(directory);errno=saved?saved:EIO;return modified?-2:-1;}
}
int hc_console_runtime_discard_unstarted(HCConsoleRuntime *r,int parent,HCConsoleSupervisor *supervisor){
 return discard_empty_workspace(r,parent,supervisor,0);
}
int hc_stock_game_discard_finished_runtime(HCStockGameSession *s,HCConsoleRuntime *r,int parent,HCConsoleSupervisor *supervisor,HCConsoleGame *game,HCStockControlSession *control){
 if(!s||!r||!game||!r->claimed||!s->finalized||s->fault||
    !control||control->save!=&s->save||!control->started||!control->finished||control->failed||control->exit_owner.save!=&s->save||control->exit_owner.phase!=2||control->exit_owner.timed_out||control->exit_owner.kill_sent||
    (control->reason!=HC_STOCK_CONTROL_RESET&&control->reason!=HC_STOCK_CONTROL_POWER)||
    !((!s->detected_no_sram&&s->save.phase==HC_STOCK_PUBLISHED)||(s->detected_no_sram&&s->save.phase==HC_STOCK_CLOSED))||
    s->save.child.pid!=-1||s->save.child.input!=-1||s->save.target.busy||!game->rom.ready||
    game->command.checkpoint.have_image||game->command.checkpoint.have_save||
    strcmp(s->game,r->request.game)||strcmp(s->rom.sha256,r->request.digest)||strcmp(game->command.game,s->game)||strcmp(game->command.digest,s->rom.sha256)||
    memcmp(s->token,r->request.session,16)||s->epoch!=r->request.epoch||
    s->rom.snapshot.st_dev!=game->rom.snapshot.st_dev||s->rom.snapshot.st_ino!=game->rom.snapshot.st_ino||
    hc_verified_launch_recheck(&game->rom)||hc_verified_launch_recheck(&s->rom)||(!s->detected_no_sram&&hc_stock_game_recheck(s))){errno=EINVAL;return -1;}
 if(hc_stock_control_refresh_finished(control))return -1;
 return discard_empty_workspace(r,parent,supervisor,1);
}
/* Match the executable pathname to the caller's independently pinned file.
 * This detects replacement, but posix_spawn still uses a pathname: the caller
 * must exclude concurrent changes through startup and while the child runs. */
static int checked_frontend(HCVerifiedLaunch *v,const char *path,uid_t uid){
 struct stat held,named;int fd;
 if(!v||!v->ready||!path||path[0]!='/'||v->snapshot.st_uid!=uid||!(v->snapshot.st_mode&S_IXUSR)||hc_verified_launch_recheck(v))return 0;
 fd=open(path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return 0;
 int ok=!fstat(fd,&named)&&!fstat(v->rom_fd,&held)&&S_ISREG(named.st_mode)&&named.st_dev==held.st_dev&&named.st_ino==held.st_ino;
 if(close(fd))return 0;return ok;
}
/* The supervisor independently verifies this lock against the reviewed SRAM
 * path before spawn. The caller still authenticates ancestry and other writers. */
static int runtime_lock_sram(const HCConsoleStartSpec *review){
 HCGameSavePaths paths;const char *root=review->profiles_root?review->profiles_root:"/var/lib/clover/profiles/0";
 if(!review->expected_sram||!review->expected_rtc||!review->verified_rom||!review->rom_name||
    strcmp(review->verified_rom->name,review->rom_name)||strcmp(review->verified_rom->sha256,review->digest)||
    hc_verified_launch_recheck(review->verified_rom)||
    hc_launch_isolated_save_paths_at_root(review->manager_argc,review->manager_argv,review->game,review->digest,root,&paths)||
    strcmp(paths.sram,review->expected_sram)||strcmp(paths.rtc,review->expected_rtc)){errno=EINVAL;return -1;}
 int profiles=open(root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(profiles<0)return -1;
 struct stat root_stat,before,opened,after;int created=0,game=-1;
 if(fstat(profiles,&root_stat)||!S_ISDIR(root_stat.st_mode)||root_stat.st_uid!=review->uid||(root_stat.st_mode&0022)){errno=EACCES;goto profile_failure;}
 if(mkdirat(profiles,review->game,0755)==0)created=1;else if(errno!=EEXIST)goto profile_failure;
 if(fstatat(profiles,review->game,&before,AT_SYMLINK_NOFOLLOW)||!S_ISDIR(before.st_mode)||before.st_uid!=review->uid||(before.st_mode&0022))goto profile_failure;
 game=openat(profiles,review->game,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(game<0)goto profile_failure;
 if(fstat(game,&opened)||fstatat(profiles,review->game,&after,AT_SYMLINK_NOFOLLOW)||
    before.st_dev!=opened.st_dev||before.st_ino!=opened.st_ino||before.st_mode!=opened.st_mode||before.st_uid!=opened.st_uid||
    after.st_dev!=opened.st_dev||after.st_ino!=opened.st_ino||after.st_mode!=opened.st_mode||after.st_uid!=opened.st_uid||
    (created&&(fsync(game)||fsync(profiles))))goto profile_failure;
 if(close(profiles)){close(game);errno=EIO;return -1;}
 int saved=0;
 int directory=hc_open_isolated_save_directory(game,review->uid,review->digest);saved=errno;
 if(close(game)&&directory>=0){close(directory);errno=EIO;return -1;}
 if(directory<0){errno=saved;return -1;}
 int lock=hc_save_directory_lock(directory,review->uid);saved=errno;
 if(close(directory)&&lock>=0){close(lock);errno=EIO;return -1;}
 if(lock<0)errno=saved;return lock;
profile_failure:
 {int error=errno?errno:EIO;if(game>=0)close(game);close(profiles);errno=error;return -1;}
}
int hc_console_runtime_prepare_game(HCConsoleRuntime *r,const HCConsoleStartSpec *review){
 if(!r||!review||r->workspace!=-1||r->save!=-1||r->image!=-1||r->report[0]!=-1||r->report[1]!=-1||r->exitpipe[0]!=-1||r->exitpipe[1]!=-1||r->exit_pin!=-1||r->frontend.ready||r->workspace_name[0]||r->supervisor||r->save_lock!=-1||r->attempted||r->claimed||r->stock_claimed||!review->game||!review->digest||review->uid!=geteuid()||review->save_lock_fd||review->save_lock_target){errno=EINVAL;return -1;}
 int lock=runtime_lock_sram(review);if(lock<0)return -1;
 /* Hold the game save lock while checking for unfinished publications.  A
  * refused start must not create another session requiring recovery. */
 size_t retained=0;
 if(hc_periodic_recovery_status(lock,review->uid,&retained)||retained){
  int saved=retained?EBUSY:errno;
  if(close(lock))saved=EIO;
  errno=saved?saved:EIO;return -1;
 }
 int parent=hc_console_runtime_open_session_parent(lock,review->uid,1);if(parent<0){int saved=errno;close(lock);errno=saved;return -1;}
 /* A crash before manager.meta is durable leaves an unattributed workspace.
  * Retain it and refuse another start while holding the game lock. A valid
  * manager record alone does not prove completion of the prior session. */
 if(hc_console_game_check_manager_record_inventory(parent,review->game,review->digest)||require_empty_session_inventory(parent)){int saved=errno?errno:EIO;if(close(parent))saved=EIO;if(close(lock))saved=EIO;errno=saved;return -1;}
 int result=hc_console_runtime_prepare(r,parent,review->uid,review->game,review->digest);int saved=errno;
 if(close(parent)&&!result){result=-1;saved=EIO;}
 /* Retain the lock on failure too: a partially created workspace may exist. */
 r->save_lock=lock;if(result)errno=saved?saved:EIO;return result;
}
int hc_console_runtime_start(HCConsoleRuntime *r,HCConsoleSupervisor *supervisor,const HCConsoleStartSpec *review,unsigned timeout,const char *core){
 unsigned char frame[HC_LAUNCH_REQUEST_SIZE];
 if(!r||!supervisor||supervisor->phase!=HC_SUPERVISOR_EMPTY||supervisor->child.pid!=-1||supervisor->child.input!=-1||!review||r->attempted||r->workspace<0||r->save<0||r->image<0||r->report[0]<0||r->report[1]<0||r->exitpipe[0]<0||r->exitpipe[1]<0||r->exit_pin<0||!checked_output(r->workspace,r->save,"state.tmp")||!checked_output(r->workspace,r->image,"image.tmp")||!checked_frontend(review->verified_frontend,review->program,review->uid)||!review->game||!review->digest||strcmp(review->game,r->request.game)||strcmp(review->digest,r->request.digest)||hc_launch_request_encode(&r->request,frame)){errno=EINVAL;return -1;}
 /* Hold our own reviewed executable descriptor until the child is reaped.
  * The pathname used by spawn must remain exclusively controlled by caller. */
 if(hc_verified_rom_open(&r->frontend,review->verified_frontend->parent,review->verified_frontend->name,review->uid,review->verified_frontend->sha256))return -1;
 if(r->frontend.snapshot.st_dev!=review->verified_frontend->snapshot.st_dev||r->frontend.snapshot.st_ino!=review->verified_frontend->snapshot.st_ino||
    !checked_frontend(&r->frontend,review->program,review->uid)||hc_verified_launch_recheck(review->verified_frontend)){
  int saved=errno;(void)hc_verified_launch_close(&r->frontend);errno=saved?saved:EIO;return -1;
 }
 HCConsoleStartSpec spec=*review;
 if(r->save_lock>=0){
  if(spec.save_lock_fd||spec.save_lock_target){(void)hc_verified_launch_close(&r->frontend);errno=EINVAL;return -1;}
  spec.save_lock_fd=r->save_lock;spec.save_lock_target=207;
 }else if(!spec.save_lock_fd&&!spec.save_lock_target){
  r->save_lock=runtime_lock_sram(review);
  if(r->save_lock<0){int saved=errno;(void)hc_verified_launch_close(&r->frontend);errno=saved;return -1;}
  spec.save_lock_fd=r->save_lock;spec.save_lock_target=207;
 }
 memcpy(spec.session,r->request.session,sizeof spec.session);spec.epoch=r->request.epoch;
 spec.report_fd=r->report[1];spec.save_fd=r->save;spec.image_fd=r->image;spec.exit_fd=r->exitpipe[1];
 r->attempted=1;r->supervisor=supervisor;
 int result=hc_console_supervisor_start_frontend(supervisor,&spec,frame,sizeof frame,timeout,core);int saved=errno;
 if(!result&&!checked_frontend(&r->frontend,review->program,review->uid)){result=-1;saved=EIO;}
 if(supervisor->phase!=HC_SUPERVISOR_EMPTY){
  if(close(r->report[1])&&result==0){result=-1;saved=errno;}r->report[1]=-1;
  if(close(r->exitpipe[1])&&result==0){result=-1;saved=errno;}r->exitpipe[1]=-1;
  if(result&&supervisor->phase!=HC_SUPERVISOR_REAPED){supervisor->phase=HC_SUPERVISOR_QUARANTINED;supervisor->recovery_required=1;}
 }
 if(result)errno=saved;return result;
}
int hc_console_runtime_start_command(HCConsoleRuntime *r,HCConsoleSupervisor *supervisor,int argc,const char *const argv[],const HCConsoleStartSpec *trusted,unsigned timeout,const char *core){
 HCCompatibilityMenuCommand command;HCGameSavePaths paths;
 if(!r||!supervisor||!trusted||hc_parse_compatibility_menu_command(argc,argv,&command)||
    hc_launch_isolated_save_paths_at_root(argc-4,argv+4,command.game,command.digest,
       trusted->profiles_root?trusted->profiles_root:"/var/lib/clover/profiles/0",&paths)) {errno=EINVAL;return -1;}
 HCConsoleStartSpec spec=*trusted;
 spec.game=command.game;spec.digest=command.digest;spec.rom_name=command.rom_name;
 spec.manager_argc=argc-4;spec.manager_argv=argv+4;spec.expected_sram=paths.sram;spec.expected_rtc=paths.rtc;
 return hc_console_runtime_start(r,supervisor,&spec,timeout,core);
}
int hc_console_runtime_observe_exit_failure(HCConsoleRuntime *r,HCConsoleSupervisor *s,unsigned timeout){
 struct stat reader,pin;
 if(!r||!s||!r->attempted||r->supervisor!=s||r->exit_observed||
    (s->phase!=HC_SUPERVISOR_CONFIRMATION_OBSERVED&&s->phase!=HC_SUPERVISOR_RELEASED_FOR_TEST&&s->phase!=HC_SUPERVISOR_QUIT_SENT_FOR_TEST)||
    s->child.pid<=0||r->exitpipe[0]<3||r->exit_pin<3||!timeout||timeout>60000){errno=EINVAL;return -1;}
 r->exit_observed=1;
 int valid=!fstat(r->exitpipe[0],&reader)&&!fstat(r->exit_pin,&pin)&&S_ISFIFO(reader.st_mode)&&S_ISFIFO(pin.st_mode)&&reader.st_dev==pin.st_dev&&reader.st_ino==pin.st_ino;
 int result=valid?hc_monitor_exit_failure(r->exitpipe[0],s->child.pid,s->session,s->epoch,timeout):-1;
 int saved=valid?errno:EPROTO;
 s->phase=HC_SUPERVISOR_QUARANTINED;s->recovery_required=1;
 if(result)errno=saved;return result;
}
int hc_console_runtime_resolve_reaped(HCConsoleRuntime *r,HCConsoleSupervisor *s,int *status){
 if(!r||!s||!status||!r->attempted||r->supervisor!=s||s->phase!=HC_SUPERVISOR_QUARANTINED||!s->recovery_required||s->child.pid!=-1){errno=EINVAL;return -1;}
 if(s->child.input>=0&&hc_console_supervisor_close_quarantined_input(s))return -1;
 return hc_console_supervisor_confirm_reaped(s,status);
}

/* Caller excludes all concurrent descriptor-table use while closing. */
static int runtime_close_owned(int *slot){
 if(*slot<0)return 0;
 int fd=*slot;*slot=-1;
 if(!close(fd))return 0;
 int saved=errno;errno=0;
 if(fcntl(fd,F_GETFD)!=-1||errno!=EBADF)*slot=fd;
 errno=saved?saved:EIO;return -1;
}
int hc_console_runtime_close(HCConsoleRuntime *r,HCConsoleSupervisor *supervisor){
 if(!r||(r->attempted&&(supervisor!=r->supervisor||!supervisor||(supervisor->phase!=HC_SUPERVISOR_REAPED&&supervisor->phase!=HC_SUPERVISOR_EMPTY)||supervisor->child.pid!=-1||supervisor->child.input!=-1||supervisor->child.reaped_pending))){errno=EBUSY;return -1;}
 int *fds[]={&r->report[0],&r->report[1],&r->exitpipe[0],&r->exitpipe[1],&r->exit_pin,&r->save,&r->image,&r->workspace};
 for(size_t i=0;i<sizeof fds/sizeof fds[0];i++)if(runtime_close_owned(fds[i]))return -1;
 if(r->frontend.ready&&hc_verified_launch_close(&r->frontend))return -1;
 return runtime_close_owned(&r->save_lock);
}
