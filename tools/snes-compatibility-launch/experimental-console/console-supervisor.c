#define _POSIX_C_SOURCE 200809L
#if defined(HC_TEST_RELEASE_ONLY) && defined(__arm__)
#error "The test-only release path must not be built for the SNES."
#endif
#include "console-supervisor.h"
#include "startup-monitor-experimental.h"
#include "startup-status.h"
#include "control_pipe.h"
#include "launch-request.h"
#include "arguments.h"
#include "recovery-binding.h"
#ifdef HC_TEST_RELEASE_ONLY
#include "control_command.h"
#endif
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>
static int game_ok(const char *game){
 if(!game||strnlen(game,12)!=11||memcmp(game,"CLV-U-",6))return 0;
 for(size_t i=6;i<11;i++)if(!((game[i]>='A'&&game[i]<='Z')||(game[i]>='0'&&game[i]<='9')))return 0;return 1;
}
/* Require one literal -s <reviewed-path> and reject option terminators. The
 * caller still authenticates the executable and all other argv elements. */
static int frontend_save_argument(char *const argv[],const char *expected){
 if(!argv||!argv[0]||!argv[1]||strcmp(argv[1],"-s")||!argv[2]||!expected||
    strnlen(argv[2],1024)>=1024||strcmp(argv[2],expected))return -1;
 for(size_t i=3;i<64;i++){
  const char *arg=argv[i];if(!arg)return 0;
  if(strnlen(arg,1024)>=1024)return -1;
  /* An earlier option can consume "--" as a value, so treating it as an
   * unconditional terminator could hide a later conflicting save option. */
  if(!strcmp(arg,"--"))return -1;
  /* Disallow getopt short-option clusters containing s, and long save
   * abbreviations/assignments; they could override the reviewed argument. */
  if(arg[0]=='-'&&arg[1]=='-'){
   const char *name=arg+2;size_t n=strcspn(name,"=");
   if(n&&n<=4&&!strncmp(name,"save",n))return -1;
  }else if(arg[0]=='-'&&arg[1]&&strchr(arg+1,'s'))return -1;
 }
 return -1;
}
/* Duplicate the already-reviewed open ROM and its parent into supervisor
 * ownership. Caller must retain exclusive control; this pins identity, not
 * executable or peer authenticity. No child starts on a failed recheck. */
static int copy_verified_rom(HCVerifiedLaunch *out,HCVerifiedLaunch *source,int directory,const char *name,uid_t uid,const char *digest){
 struct stat a,b;int flags=fcntl(directory,F_GETFD);
 if(!out||out->ready||!source||!source->ready||!name||!digest||strcmp(source->name,name)||strcmp(source->sha256,digest)||
    flags<0||!(flags&FD_CLOEXEC)||source->snapshot.st_uid!=uid||fstat(directory,&a)||fstat(source->parent,&b)||a.st_dev!=b.st_dev||a.st_ino!=b.st_ino||
    hc_verified_launch_recheck(source)){errno=EINVAL;return -1;}
 int parent=fcntl(source->parent,F_DUPFD_CLOEXEC,3);if(parent<0)return -1;
 int rom=fcntl(source->rom_fd,F_DUPFD_CLOEXEC,3);if(rom<0){int e=errno;close(parent);errno=e;return -1;}
 *out=*source;out->parent=parent;out->rom_fd=rom;
 if(hc_verified_launch_recheck(out)){int e=errno;hc_verified_launch_close(out);errno=e;return -1;}
 return 0;
}
static int hc_console_supervisor_start(HCConsoleSupervisor *s,HCVerifiedLaunch *reviewed,int d,const char *name,uid_t uid,const char *game,const char *digest,const uint8_t session[16],uint64_t epoch,const char *program,char *const argv[],char *const envp[],int report,int report_target,int save,int save_target,int image,int image_target,int startup,int startup_target,int exitfd,int exit_target,int rom_target,int confirm,int confirm_target,int lock,int lock_target){
 uint8_t frame[HC_STARTUP_FRAME_SIZE];
 if(!s||s->phase!=HC_SUPERVISOR_EMPTY||s->child.pid!=-1||s->child.input!=-1||s->rom.ready||!game_ok(game)||hc_startup_encode(frame,session,epoch,HC_STARTUP_OK)){errno=EINVAL;return -1;}
 if(reviewed ? copy_verified_rom(&s->rom,reviewed,d,name,uid,digest) : hc_verified_rom_open(&s->rom,d,name,uid,digest))return -1;
 int started=hc_verified_launch_recheck(&s->rom)?-1:(lock>=0?hc_child_start_confirmed_lock(&s->child,program,argv,envp,report,report_target,save,save_target,image,image_target,startup,startup_target,exitfd,exit_target,s->rom.rom_fd,rom_target,confirm,confirm_target,lock,lock_target):hc_child_start_confirmed(&s->child,program,argv,envp,report,report_target,save,save_target,image,image_target,startup,startup_target,exitfd,exit_target,s->rom.rom_fd,rom_target,confirm,confirm_target));
 if(started){
  int saved=errno;(void)hc_verified_launch_close(&s->rom);errno=saved?saved:EIO;return -1;
 }
 memcpy(s->session,session,16);s->epoch=epoch;memcpy(s->game,game,12);s->phase=HC_SUPERVISOR_CHILD_STARTED;return 0;
}
static int start_owned(HCConsoleSupervisor *s,HCVerifiedLaunch *reviewed,int d,const char *name,uid_t uid,const char *game,const char *digest,const uint8_t session[16],uint64_t epoch,const char *program,char *const argv[],char *const envp[],int report,int report_target,int save,int save_target,int image,int image_target,int startup_target,int exitfd,int exit_target,int rom_target,int confirm_target,int lock,int lock_target){
 int a[2]={-1,-1},b[2]={-1,-1},ap=-1,bp=-1;
 if(!s||s->startup_reader!=-1||s->confirmation_reader!=-1||s->startup_pin!=-1||s->confirmation_pin!=-1){errno=EINVAL;return -1;}
 if(hc_control_pipe(a))return -1;
 if(hc_control_pipe(b)){int e=errno;close(a[0]);close(a[1]);errno=e;return -1;}
 ap=fcntl(a[0],F_DUPFD_CLOEXEC,3);if(ap>=0)bp=fcntl(b[0],F_DUPFD_CLOEXEC,3);
 if(ap<0||bp<0){int e=errno;if(ap>=0)close(ap);if(bp>=0)close(bp);close(a[0]);close(a[1]);close(b[0]);close(b[1]);errno=e;return -1;}
 if(hc_console_supervisor_start(s,reviewed,d,name,uid,game,digest,session,epoch,program,argv,envp,report,report_target,save,save_target,image,image_target,a[1],startup_target,exitfd,exit_target,rom_target,b[1],confirm_target,lock,lock_target)){
  int e=errno;close(ap);close(bp);close(a[0]);close(a[1]);close(b[0]);close(b[1]);errno=e;return -1;
 }
 s->startup_reader=a[0];s->confirmation_reader=b[0];s->startup_pin=ap;s->confirmation_pin=bp;
 int ca=close(a[1]),cb=close(b[1]);
 if(ca||cb){s->phase=HC_SUPERVISOR_QUARANTINED;s->recovery_required=1;errno=EIO;return -1;}
 return 0;
}
int hc_console_supervisor_start_owned(HCConsoleSupervisor *s,int d,const char *name,uid_t uid,const char *game,const char *digest,const uint8_t session[16],uint64_t epoch,const char *program,char *const argv[],char *const envp[],int report,int report_target,int save,int save_target,int image,int image_target,int startup_target,int exitfd,int exit_target,int rom_target,int confirm_target){
 return start_owned(s,NULL,d,name,uid,game,digest,session,epoch,program,argv,envp,report,report_target,save,save_target,image,image_target,startup_target,exitfd,exit_target,rom_target,confirm_target,-1,-1);
}
/* Pins keep each original reader alive so replacing its public descriptor cannot
 * silently redirect a report. The trusted caller still owns all descriptors. */
static int same_reader(int fd,int pin){struct stat a,b;return fd>=3&&pin>=3&&!fstat(fd,&a)&&!fstat(pin,&b)&&S_ISFIFO(a.st_mode)&&S_ISFIFO(b.st_mode)&&a.st_dev==b.st_dev&&a.st_ino==b.st_ino;}
static int hc_console_supervisor_send_launch(HCConsoleSupervisor *s){
 if(!s||s->phase!=HC_SUPERVISOR_CHILD_STARTED||s->launch_sent){errno=EINVAL;return -1;}
 HCLaunchRequest request={0};memcpy(request.game,s->game,sizeof request.game);memcpy(request.digest,s->rom.sha256,sizeof request.digest);memcpy(request.session,s->session,sizeof request.session);request.epoch=s->epoch;
 s->launch_sent=1;
 if(hc_verified_launch_recheck(&s->rom)||hc_launch_request_send(s->child.input,&request)){
  int e=errno;s->phase=HC_SUPERVISOR_QUARANTINED;s->recovery_required=1;errno=e?e:EIO;return -1;
 }
 return 0;
}
int hc_console_supervisor_send_reviewed_frame(HCConsoleSupervisor *s,const unsigned char *frame,size_t length){
 if(!s||s->phase!=HC_SUPERVISOR_CHILD_STARTED||s->launch_sent){errno=EINVAL;return -1;}
 HCLaunchRequest request={0};
 if(hc_launch_request_decode(frame,length,&request)||strcmp(request.game,s->game)||strcmp(request.digest,s->rom.sha256)||memcmp(request.session,s->session,16)||request.epoch!=s->epoch){
  s->launch_sent=1;s->phase=HC_SUPERVISOR_QUARANTINED;s->recovery_required=1;errno=EPROTO;return -1;
 }
 return hc_console_supervisor_send_launch(s);
}
static void record_startup_failure(HCConsoleSupervisor *s,int stage,int monitor_result,int monitor_errno){
 s->startup_failure_stage=stage;
 s->startup_failure_kind=!monitor_result?HC_START_FAILURE_REPORTED:
  monitor_errno==ETIMEDOUT?HC_START_FAILURE_TIMEOUT:
  monitor_errno==EPROTO?HC_START_FAILURE_PROTOCOL:HC_START_FAILURE_TRANSPORT;
}
int hc_console_supervisor_observe_startup(HCConsoleSupervisor *s,int fd,unsigned timeout){
 int status=0;if(!s||s->phase!=HC_SUPERVISOR_CHILD_STARTED){errno=EINVAL;return -1;}
 if(!s->launch_sent||fd!=s->startup_reader||!same_reader(fd,s->startup_pin)){record_startup_failure(s,HC_START_STAGE_INITIAL,-1,EPROTO);s->phase=HC_SUPERVISOR_QUARANTINED;s->recovery_required=1;errno=EPROTO;return -1;}
 int result=hc_monitor_startup_result(fd,s->child.pid,s->session,s->epoch,timeout,&status);
 if(result||status!=HC_STARTUP_OK){int saved=result?errno:EPROTO;record_startup_failure(s,HC_START_STAGE_INITIAL,result,saved);s->phase=HC_SUPERVISOR_QUARANTINED;s->recovery_required=1;errno=saved?saved:EIO;return -1;}
 /* A report is not child-confirmed readiness. No game-start action follows. */
 s->phase=HC_SUPERVISOR_STARTUP_OBSERVED;return 0;
}
int hc_console_supervisor_observe_confirmation(HCConsoleSupervisor *s,int fd,unsigned timeout){
 int status=0;if(!s||s->phase!=HC_SUPERVISOR_STARTUP_OBSERVED){errno=EINVAL;return -1;}
 if(fd!=s->confirmation_reader||!same_reader(fd,s->confirmation_pin)){record_startup_failure(s,HC_START_STAGE_CONFIRMATION,-1,EPROTO);s->phase=HC_SUPERVISOR_QUARANTINED;s->recovery_required=1;errno=EPROTO;return -1;}
 int result=hc_monitor_startup_result(fd,s->child.pid,s->session,s->epoch,timeout,&status);
 if(result||status!=HC_STARTUP_OK){int saved=result?errno:EPROTO;record_startup_failure(s,HC_START_STAGE_CONFIRMATION,result,saved);s->phase=HC_SUPERVISOR_QUARANTINED;s->recovery_required=1;errno=saved?saved:EIO;return -1;}
 /* This is another observation, not authorization or shutdown proof. */
 s->phase=HC_SUPERVISOR_CONFIRMATION_OBSERVED;return 0;
}
#ifdef HC_TEST_RELEASE_ONLY
int hc_console_supervisor_release_game_for_test(HCConsoleSupervisor *s){
 if(!s||s->phase!=HC_SUPERVISOR_CONFIRMATION_OBSERVED||!s->launch_sent){errno=EINVAL;return -1;}
 int status,live=hc_console_supervisor_poll(s,&status);
 if(live){s->phase=live>0?HC_SUPERVISOR_REAPED:HC_SUPERVISOR_QUARANTINED;s->recovery_required=1;if(live>0)errno=ECHILD;return -1;}
 HCLaunchRequest request={0};memcpy(request.game,s->game,sizeof request.game);memcpy(request.digest,s->rom.sha256,sizeof request.digest);memcpy(request.session,s->session,sizeof request.session);request.epoch=s->epoch;
 if(hc_verified_launch_recheck(&s->rom)||hc_launch_release_send(s->child.input,&request)){
  int e=errno;s->phase=HC_SUPERVISOR_QUARANTINED;s->recovery_required=1;errno=e?e:EIO;return -1;
 }
 s->phase=HC_SUPERVISOR_RELEASED_FOR_TEST;return 0;
}
int hc_console_supervisor_request_quit_for_test(HCConsoleSupervisor *s){
 if(!s||s->phase!=HC_SUPERVISOR_RELEASED_FOR_TEST){errno=EINVAL;return -1;}
 int status,live=hc_console_supervisor_poll(s,&status);
 if(live){s->phase=live>0?HC_SUPERVISOR_REAPED:HC_SUPERVISOR_QUARANTINED;s->recovery_required=1;if(live>0)errno=ECHILD;return -1;}
 if(hc_control_command(s->child.input,HC_COMMAND_QUIT)){
  int e=errno;s->phase=HC_SUPERVISOR_QUARANTINED;s->recovery_required=1;errno=e?e:EIO;return -1;
 }
 s->phase=HC_SUPERVISOR_QUIT_SENT_FOR_TEST;return 0;
}

#endif
/* Match a caller-held lock to the reviewed game's save directory. The caller
 * must authenticate the path ancestry and exclude uncooperative writers. */
static int checked_save_lock(int fd,int target,const char *sram,uid_t uid){
 char parent[HC_ARGUMENT_BYTES];struct stat held,named;const char *slash=strrchr(sram,'/');
 if(fd<3||target<3||target>255||!slash||strcmp(slash+1,"battery.srm")||slash==sram||(size_t)(slash-sram)>=sizeof parent){errno=EINVAL;return -1;}
 memcpy(parent,sram,(size_t)(slash-sram));parent[slash-sram]=0;
 int flags=fcntl(fd,F_GETFD);if(flags<0||!(flags&FD_CLOEXEC)||fstat(fd,&held)||!S_ISDIR(held.st_mode)||held.st_uid!=uid||(held.st_mode&0777)!=0700){errno=EINVAL;return -1;}
 int directory=open(parent,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(directory<0)return -1;
 int bad=fstat(directory,&named)||held.st_dev!=named.st_dev||held.st_ino!=named.st_ino||!S_ISDIR(named.st_mode)||flock(fd,LOCK_EX|LOCK_NB);
 int saved=errno;if(close(directory))bad=1;if(bad){errno=saved?saved:EIO;return -1;}return 0;
}
int hc_console_supervisor_start_reviewed(HCConsoleSupervisor *s,const HCConsoleStartSpec *spec,const unsigned char *frame,size_t length,unsigned timeout){
 HCLaunchRequest request={0};HCGameSavePaths saves;
 if(!s||s->phase!=HC_SUPERVISOR_EMPTY||!spec||!spec->verified_rom||!frame||!timeout||timeout>60000||!spec->game||!spec->digest||!spec->expected_sram||!spec->expected_rtc||
    strnlen(spec->game,12)!=11||strnlen(spec->digest,65)!=64||
    strnlen(spec->expected_sram,HC_ARGUMENT_BYTES)>=HC_ARGUMENT_BYTES||strnlen(spec->expected_rtc,HC_ARGUMENT_BYTES)>=HC_ARGUMENT_BYTES||
    hc_launch_request_decode(frame,length,&request)||strcmp(request.game,spec->game)||
    strcmp(request.digest,spec->digest)||memcmp(request.session,spec->session,16)||request.epoch!=spec->epoch||
    hc_launch_isolated_save_paths_at_root(spec->manager_argc,spec->manager_argv,spec->game,spec->digest,
       spec->profiles_root?spec->profiles_root:"/var/lib/clover/profiles/0",&saves)||
    strcmp(saves.sram,spec->expected_sram)||strcmp(saves.rtc,spec->expected_rtc)||
    frontend_save_argument(spec->argv,saves.sram)){errno=EINVAL;return -1;}
 int use_lock=spec->save_lock_fd!=0||spec->save_lock_target!=0;
 if(use_lock&&checked_save_lock(spec->save_lock_fd,spec->save_lock_target,saves.sram,spec->uid))return -1;
 int started=start_owned(s,spec->verified_rom,spec->directory,spec->rom_name,spec->uid,spec->game,spec->digest,spec->session,spec->epoch,
    spec->program,spec->argv,spec->envp,spec->report_fd,spec->report_target,spec->save_fd,spec->save_target,spec->image_fd,spec->image_target,
    spec->startup_target,spec->exit_fd,spec->exit_target,spec->rom_target,spec->confirm_target,use_lock?spec->save_lock_fd:-1,use_lock?spec->save_lock_target:-1);
 /* Retain the validated save identities even when a spawned child is later
  * quarantined, so recovery cannot be redirected to another game. */
 if(s->phase!=HC_SUPERVISOR_EMPTY){memcpy(s->sram_path,saves.sram,strlen(saves.sram)+1);memcpy(s->rtc_path,saves.rtc,strlen(saves.rtc)+1);}
 if(started)return -1;
 if(hc_console_supervisor_send_reviewed_frame(s,frame,length)||
    hc_console_supervisor_observe_startup(s,s->startup_reader,timeout)||
    hc_console_supervisor_observe_confirmation(s,s->confirmation_reader,timeout))return -1;
 return 0;
}
/* The root is supplied by the trusted caller, not by a menu entry. Reject
 * ambiguous spellings and bind it to the already verified directory. */
static int object_root_matches(const char *root,int directory){
 if(!root||root[0]!='/'||!root[1]||strnlen(root,900)>=900)return 0;
 size_t begin=1;
 for(size_t i=1;;i++){
  unsigned char c=(unsigned char)root[i];
  if(!c||c=='/'){
   size_t n=i-begin;if(!n||(n==1&&root[begin]=='.')||(n==2&&root[begin]=='.'&&root[begin+1]=='.'))return 0;
   if(!c)break;begin=i+1;continue;
  }
  if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='_'||c=='-'||c=='.'))return 0;
 }
 int fd=open(root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return 0;
 struct stat a,b;int match=!fstat(fd,&a)&&!fstat(directory,&b)&&S_ISDIR(a.st_mode)&&a.st_dev==b.st_dev&&a.st_ino==b.st_ino;
 if(close(fd))return 0;return match;
}
int hc_console_supervisor_start_frontend(HCConsoleSupervisor *s,const HCConsoleStartSpec *spec,const unsigned char *frame,size_t length,unsigned timeout,const char *core){
 HCLaunchRequest request={0};HCLaunchArguments manager={0};char session_hex[HC_LAUNCH_REQUEST_SIZE*2+1],rom_path[1024],rollback_save[1024];static const char hex[]="0123456789abcdef";
 if(!spec||!spec->program||!spec->expected_sram||!spec->rom_name||!core||core[0]!='/'||strnlen(core,1024)>=1024||
    hc_launch_request_decode(frame,length,&request)||hc_launch_arguments(spec->manager_argc,spec->manager_argv,request.game,&manager)){errno=EINVAL;return -1;}
 const char *objects=spec->objects_root?spec->objects_root:"/var/lib/swifthakchi/snes-v2/objects";
 if(!object_root_matches(objects,spec->directory)){errno=EINVAL;return -1;}
 size_t n=strnlen(spec->rom_name,69);
 if(n!=68||memcmp(spec->rom_name,request.digest,64)||(strcmp(spec->rom_name+64,".sfc")&&strcmp(spec->rom_name+64,".smc"))){errno=EINVAL;return -1;}
 int k=snprintf(rom_path,sizeof rom_path,"%s/%s",objects,spec->rom_name);
 if(k<=0||(size_t)k>=sizeof rom_path){errno=EINVAL;return -1;}
 for(size_t i=0;i<length;i++){session_hex[2*i]=hex[frame[i]>>4];session_hex[2*i+1]=hex[frame[i]&15];}session_hex[length*2]=0;
 char *args[13]={(char *)spec->program,"-s",(char *)spec->expected_sram,"--hc-session-frame",session_hex};
 int at=5;if(manager.present&(1u<<HC_SCREENSHOT)){args[at++]="--hc-manager-screenshot";args[at++]=manager.values[HC_SCREENSHOT];}
 const char *save=NULL;
 if(manager.present&(1u<<HC_SAVE))save=manager.values[HC_SAVE];
 else if(manager.present&(1u<<HC_ROLLBACK_OUT)){
  int written=snprintf(rollback_save,sizeof rollback_save,"%s/savestate",manager.values[HC_ROLLBACK_OUT]);
  if(written<=0||(size_t)written>=sizeof rollback_save){errno=EINVAL;return -1;}save=rollback_save;
 }
 if(save){args[at++]="--hc-manager-save";args[at++]=(char *)save;}
 args[at++]="-L";args[at++]=(char *)core;args[at++]=rom_path;args[at]=NULL;
 HCConsoleStartSpec prepared=*spec;prepared.argv=args;
 return hc_console_supervisor_start_reviewed(s,&prepared,frame,length,timeout);
}
static int supervisor_recovery_matches(HCConsoleSupervisor *s,const HCSessionExpected *regions,size_t count,size_t index){
 if(!s||s->phase!=HC_SUPERVISOR_REAPED||s->child.pid!=-1||s->child.input!=-1||!s->recovery_required||!s->rom.ready||
    !s->sram_path[0]||!s->rtc_path[0]||!regions||count!=2||index>=count||!regions[0].identity||!regions[1].identity||
    regions[0].type!=0||regions[1].type!=1||strcmp(regions[0].identity,s->sram_path)||strcmp(regions[1].identity,s->rtc_path)||
    hc_verified_launch_recheck(&s->rom)){errno=EINVAL;return -1;}
 return 0;
}
int hc_console_supervisor_restore_previous(HCConsoleSupervisor *s,int binding_dir,const char *binding,const HCSessionExpected *regions,size_t count,size_t index,const char *workspace,const void *expected,size_t length){
 if(supervisor_recovery_matches(s,regions,count,index))return -1;
 return hc_binding_restore_previous(binding_dir,binding,s->game,s->rom.sha256,s->session,s->epoch,regions,count,index,workspace,expected,length);
}
int hc_console_supervisor_restore_absent(HCConsoleSupervisor *s,int binding_dir,const char *binding,const HCSessionExpected *regions,size_t count,size_t index,const char *workspace,const void *expected,size_t length){
 if(supervisor_recovery_matches(s,regions,count,index))return -1;
 return hc_binding_restore_absent(binding_dir,binding,s->game,s->rom.sha256,s->session,s->epoch,regions,count,index,workspace,expected,length);
}
int hc_console_supervisor_poll(HCConsoleSupervisor *s,int *status){
 if(!s||!status||(s->phase!=HC_SUPERVISOR_CHILD_STARTED&&s->phase!=HC_SUPERVISOR_STARTUP_OBSERVED&&s->phase!=HC_SUPERVISOR_CONFIRMATION_OBSERVED&&s->phase!=HC_SUPERVISOR_QUARANTINED
#ifdef HC_TEST_RELEASE_ONLY
    &&s->phase!=HC_SUPERVISOR_RELEASED_FOR_TEST&&s->phase!=HC_SUPERVISOR_QUIT_SENT_FOR_TEST
#endif
    )){errno=EINVAL;return -1;}
 int r=hc_child_poll(&s->child,status);if(r==1){s->phase=HC_SUPERVISOR_REAPED;s->recovery_required=1;}else if(r<0){int saved=errno;s->phase=HC_SUPERVISOR_QUARANTINED;s->recovery_required=1;if(s->child.pid==-1&&s->child.input>=0)(void)hc_console_supervisor_close_quarantined_input(s);errno=saved;}return r;
}
int hc_console_supervisor_close_quarantined_input(HCConsoleSupervisor *s){
 if(!s||s->phase!=HC_SUPERVISOR_QUARANTINED||!s->recovery_required||s->child.pid!=-1){errno=EBUSY;return -1;}
 return hc_child_close_input(&s->child);
}
int hc_console_supervisor_confirm_reaped(HCConsoleSupervisor *s,int *status){
 if(!s||!status||s->phase!=HC_SUPERVISOR_QUARANTINED||!s->recovery_required){errno=EINVAL;return -1;}
 int result=hc_child_take_reaped(&s->child,status);
 if(result==1)s->phase=HC_SUPERVISOR_REAPED;
 return result;
}
/* Caller excludes concurrent descriptor-table reuse during cleanup. */
static int supervisor_close_owned(int *slot){
 if(*slot<0)return 0;
 int fd=*slot;*slot=-1;
 if(!close(fd))return 0;
 int saved=errno;errno=0;
 if(fcntl(fd,F_GETFD)!=-1||errno!=EBADF)*slot=fd;
 errno=saved?saved:EIO;return -1;
}
int hc_console_supervisor_release(HCConsoleSupervisor *s){
 if(!s||s->phase!=HC_SUPERVISOR_REAPED||s->child.pid!=-1||s->child.input!=-1||s->child.reaped_pending||!s->rom.ready){errno=EINVAL;return -1;}
 int *fds[]={&s->startup_reader,&s->confirmation_reader,&s->startup_pin,&s->confirmation_pin};
 for(size_t i=0;i<sizeof fds/sizeof fds[0];i++)if(supervisor_close_owned(fds[i]))return -1;
 return hc_verified_launch_close(&s->rom);
}
