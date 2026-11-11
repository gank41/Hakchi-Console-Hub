#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
/* Offline preflight entry point. Console launch is intentionally unavailable
 * until frontend bootstrap, shutdown, recovery and hardware checks are done. */
#include "verified-launch.h"
#include "console-support.h"
#include "console-game.h"
#include "arguments.h"
#include "launch-request.h"
#ifdef HC_ENABLE_SELECTED_PARENT_PREFLIGHT
#include "stock-selected-state.h"
#endif
#ifdef HC_ENABLE_RECOVERY_OBSERVER
#include "recovery-observer.h"
#include "recovery-clock-wire.h"
#endif
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/stat.h>
#include <unistd.h>
#if defined(HC_TEST_CLOCK_FRAME_TIMEOUT_MS) && defined(__arm__)
#error "A shortened clock-request timeout is only for host tests."
#endif
#ifndef HC_TEST_CLOCK_FRAME_TIMEOUT_MS
#define HC_CLOCK_FRAME_TIMEOUT_MS 30000
#else
#define HC_CLOCK_FRAME_TIMEOUT_MS HC_TEST_CLOCK_FRAME_TIMEOUT_MS
#endif
#if (defined(HC_TEST_OBJECT_DIRECTORY) || defined(HC_HOST_GAME_RUNNER) || defined(HC_TEST_PROFILES_DIRECTORY)) && defined(__arm__)
#error "Host test object directory cannot be used on the console."
#endif
#ifndef HC_TEST_OBJECT_DIRECTORY
#define HC_OBJECT_DIRECTORY "/var/lib/swifthakchi/snes-v2/objects"
#else
#define HC_OBJECT_DIRECTORY HC_TEST_OBJECT_DIRECTORY
#endif
#if defined(HC_TEST_COMPAT_SUPPORT_DIRECTORY) && defined(__arm__)
#error "A test support directory is not valid on the console."
#endif
#ifndef HC_TEST_COMPAT_SUPPORT_DIRECTORY
#define HC_COMPAT_SUPPORT_DIRECTORY "/mnt/swifthakchi/snes-compat"
#else
#define HC_COMPAT_SUPPORT_DIRECTORY HC_TEST_COMPAT_SUPPORT_DIRECTORY
#endif
/* This observation does not authorize execution or prove live console support. */
static int check_compatibility_support(void){
 HCConsoleSupport support=HC_CONSOLE_SUPPORT_INITIALIZER;
 int result=hc_console_support_open(&support,HC_COMPAT_SUPPORT_DIRECTORY,geteuid());
 if(!result&&hc_console_support_recheck(&support))result=-1;
 if(hc_console_support_close(&support))result=-1;
 if(result){fputs("Compatibility support could not be verified. Console launch is not enabled.\n",stderr);return 1;}
 return puts("COMPATIBILITY SUPPORT MATCHES\nConsole launch is not enabled.")==EOF;
}
static int game_ok(const char *s){if(!s||strnlen(s,12)!=11||memcmp(s,"CLV-U-",6))return 0;for(size_t i=6;i<11;i++)if(!((s[i]>='A'&&s[i]<='Z')||(s[i]>='0'&&s[i]<='9')))return 0;return 1;}
/* A single closed input is required for this offline check. */
static int input_finished(void){
 struct pollfd p={STDIN_FILENO,POLLIN|POLLHUP,0};int r;
 do r=poll(&p,1,1000);while(r<0&&errno==EINTR);
 if(r<=0||(p.revents&(POLLERR|POLLNVAL)))return -1;
 unsigned char extra;ssize_t n;do n=read(STDIN_FILENO,&extra,1);while(n<0&&errno==EINTR);
 return n==0?0:-1;
}
#ifdef HC_ENABLE_RECOVERY_OBSERVER
#ifndef HC_TEST_PROFILES_DIRECTORY
#define HC_RECOVERY_PROFILES_DIRECTORY "/var/lib/clover/profiles/0"
#else
#define HC_RECOVERY_PROFILES_DIRECTORY HC_TEST_PROFILES_DIRECTORY
#endif
/* Correlation evidence only: this read-only command does not authenticate the
 * attached console, stop writers, or authorize a recovery operation. */
static int observe_recovery(void){
 HCLaunchRequest request={0};HCRecoveryObservation observation;int flags=fcntl(STDIN_FILENO,F_GETFL);
 if(flags<0||fcntl(STDIN_FILENO,F_SETFL,flags|O_NONBLOCK)||hc_launch_request_receive(STDIN_FILENO,3000,&request)||input_finished())return 1;
 int parent=open(HC_RECOVERY_PROFILES_DIRECTORY,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(parent<0)return 1;
 int result=hc_recovery_observe_game(parent,HC_RECOVERY_PROFILES_DIRECTORY,geteuid(),&request,0,&observation);
 int closed=close(parent);if(result||closed)return 1;
 char frame[24576];int n=snprintf(frame,sizeof frame,"HC-RECOVERY-OBS-1\n%" PRIu64 " %" PRIu64 " %zu %zu\n",observation.device,observation.inode,observation.descriptor_length,observation.entry_count);
 if(n<0||(size_t)n>=sizeof frame||observation.descriptor_length>=sizeof frame-(size_t)n)return 1;
 size_t used=(size_t)n;memcpy(frame+used,observation.descriptor,observation.descriptor_length);used+=observation.descriptor_length;
 for(size_t i=0;i<observation.entry_count;i++){
  const HCIV2Entry *e=&observation.entries[i];n=snprintf(frame+used,sizeof frame-used,"ENTRY %s %s %s %d %d\n",e->session,e->workspace,e->region,(int)e->kind,e->workspace_present);
  if(n<0||(size_t)n>=sizeof frame-used)return 1;used+=(size_t)n;
 }
 n=snprintf(frame+used,sizeof frame-used,"HC-RECOVERY-OBS-END\n");if(n<0||(size_t)n>=sizeof frame-used)return 1;used+=(size_t)n;
 size_t pos=0;while(pos<used){ssize_t written=write(STDOUT_FILENO,frame+pos,used-pos);if(written<0&&errno==EINTR)continue;if(written<=0)return 1;pos+=(size_t)written;}
 return 0;
}
static int recovery_write(const void *data,size_t length){
 const unsigned char *p=data;size_t pos=0;while(pos<length){ssize_t n=write(STDOUT_FILENO,p+pos,length-pos);if(n<0&&errno==EINTR)continue;if(n<=0)return -1;pos+=(size_t)n;}return 0;
}
/* Read-only retained state. A matching session and descriptor are correlation
 * evidence, not console authentication, writer exclusion or restore approval. */
typedef int (*HCGameRetainedCollector)(int,const char *,uid_t,const HCLaunchRequest *,int,HCRecoveryObservation *,void *,size_t,size_t *);
static int observe_retained_checkpoint(const char *variant,const char *single,const char *prefix,const char *footer,size_t maximum,HCGameRetainedCollector collector){
 int paired;if(!strcmp(variant,single))paired=0;else if(!strcmp(variant,"paired"))paired=1;else return 1;
 HCLaunchRequest request={0};int flags=fcntl(STDIN_FILENO,F_GETFL);
 if(flags<0||fcntl(STDIN_FILENO,F_SETFL,flags|O_NONBLOCK)||hc_launch_request_receive(STDIN_FILENO,3000,&request)||input_finished())return 1;
 int parent=open(HC_RECOVERY_PROFILES_DIRECTORY,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(parent<0)return 1;
 HCRecoveryObservation *observation=calloc(1,sizeof *observation);unsigned char *bytes=malloc(maximum);size_t length=0;int result=-1;
 if(observation&&bytes&&!collector(parent,HC_RECOVERY_PROFILES_DIRECTORY,geteuid(),&request,paired,observation,bytes,maximum,&length))result=0;
 if(close(parent))result=-1;if(result)goto done;
 char header[256];int n=snprintf(header,sizeof header,"%s\n%" PRIu64 " %" PRIu64 " %zu %zu %zu\n",prefix,observation->device,observation->inode,observation->descriptor_length,observation->entry_count,length);
 if(n<0||(size_t)n>=sizeof header||recovery_write(header,(size_t)n)||recovery_write(observation->descriptor,observation->descriptor_length)){result=-1;goto done;}
 for(size_t i=0;i<observation->entry_count;i++){const HCIV2Entry *e=&observation->entries[i];n=snprintf(header,sizeof header,"ENTRY %s %s %s %d %d\n",e->session,e->workspace,e->region,(int)e->kind,e->workspace_present);if(n<0||(size_t)n>=sizeof header||recovery_write(header,(size_t)n)){result=-1;goto done;}}
 if(recovery_write(bytes,length)||recovery_write(footer,strlen(footer)))result=-1;
done: free(observation);free(bytes);return result?1:0;
}
static int observe_retained_state(const char *variant){return observe_retained_checkpoint(variant,"save","HC-RETAINED-STATE-1","HC-RETAINED-STATE-END\n",16u*1024u*1024u,hc_recovery_collect_game_state);}
#ifdef HC_ENABLE_STATE_ARCHIVE
/* Bounded read-only observation: matching data does not authorize restore. */
static int collect_state_archive(int profiles,const char *root,uid_t uid,const HCLaunchRequest *request,int paired,HCRecoveryObservation *observation,void *bytes,size_t capacity,size_t *length){
 if(paired){errno=EINVAL;return -1;}return hc_recovery_collect_game_state_archive(profiles,root,uid,request,observation,bytes,capacity,length);
}
static int observe_state_archive(void){return observe_retained_checkpoint("state","state","HC-STATE-ARCHIVE-1","HC-STATE-ARCHIVE-END\n",16u*1024u*1024u,collect_state_archive);}
#endif
#ifdef HC_ENABLE_RETAINED_IMAGE
static int observe_retained_image(const char *variant){return observe_retained_checkpoint(variant,"image","HC-RETAINED-IMAGE-1","HC-RETAINED-IMAGE-END\n",8u*1024u*1024u,hc_recovery_collect_game_image);}
static int observe_retired_image(const char *variant){return observe_retained_checkpoint(variant,"image","HC-RETIRED-IMAGE-1","HC-RETIRED-IMAGE-END\n",8u*1024u*1024u,hc_recovery_collect_game_retired_image);}
#endif
#ifdef HC_ENABLE_RETAINED_TIME
/* Read-only evidence only: this does not authenticate a console or approve a
 * restore, and callers must independently ensure all writers have stopped. */
static int collect_time_seed(int profiles,const char *root,uid_t uid,const HCLaunchRequest *request,int paired,HCRecoveryObservation *observation,void *bytes,size_t capacity,size_t *length){
 if(paired){errno=EINVAL;return -1;}return hc_recovery_collect_game_time_seed(profiles,root,uid,request,observation,bytes,capacity,length);
}
static int observe_retained_time(void){return observe_retained_checkpoint("time","time","HC-RETAINED-TIME-1","HC-RETAINED-TIME-END\n",21,collect_time_seed);}
#endif
#ifdef HC_ENABLE_MANAGER_INVENTORY
/* Read-only discovery. Records remain untrusted correlation data; the caller
 * must authenticate the console and exclude writers before using evidence. */
static int observe_manager_inventory(const char *game,const char *digest){
 int profiles=-1,parent=-1,workspace=-1,ok=0;size_t count=0,used=10;
 HCManagerRecordObservation *items=calloc(16,sizeof *items);unsigned char *frame=malloc(10+16*(2+HC_MANAGER_RECORD_MAX));
 if(!items||!frame)goto done;
 profiles=open(HC_RECOVERY_PROFILES_DIRECTORY,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(profiles<0)goto done;
 parent=hc_console_game_open_persistent_sessions(profiles,HC_RECOVERY_PROFILES_DIRECTORY,geteuid(),game,digest);if(parent==-1)goto done;
 if(parent>=0&&hc_console_game_inventory_manager_records(parent,game,digest,items,16,&count))goto done;
 memcpy(frame,"HCMINV2\0",8);frame[8]=(unsigned char)count;frame[9]=(unsigned char)(count>>8);
 for(size_t i=0;i<count;i++){
  if(items[i].status==HC_MANAGER_RECORD_INCOMPLETE){frame[used]=43;frame[used+1]=0;memcpy(frame+used+2,items[i].workspace,43);used+=45;continue;}
  if(items[i].status!=HC_MANAGER_RECORD_PRESENT)goto done;
  size_t length=0;workspace=openat(parent,items[i].workspace,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(workspace<0)goto done;
  if(hc_console_game_export_manager_record(workspace,game,digest,frame+used+2,HC_MANAGER_RECORD_MAX,&length)||length<119||length>HC_MANAGER_RECORD_MAX||
     hc_console_game_check_manager_record_full(workspace,&items[i].request,&items[i].paths,&items[i].time))goto done;
  frame[used]=(unsigned char)length;frame[used+1]=(unsigned char)(length>>8);used+=2+length;
  if(close(workspace))goto done;workspace=-1;
 }
 if(recovery_write(frame,used))goto done;ok=1;
done: if(workspace>=0&&close(workspace))ok=0;if(parent>=0&&close(parent))ok=0;if(profiles>=0&&close(profiles))ok=0;free(items);free(frame);return ok?0:1;
}
#endif
/* A bounded read-only current-save snapshot. This is not authentication,
 * stopped-writer proof, or authority to restore a console. */
static int observe_recovery_save(const char *region){
 size_t index;if(!strcmp(region,"sram"))index=0;else if(!strcmp(region,"rtc"))index=1;else return 1;
 HCLaunchRequest request={0};int flags=fcntl(STDIN_FILENO,F_GETFL);
 if(flags<0||fcntl(STDIN_FILENO,F_SETFL,flags|O_NONBLOCK)||hc_launch_request_receive(STDIN_FILENO,3000,&request)||input_finished())return 1;
 int parent=open(HC_RECOVERY_PROFILES_DIRECTORY,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(parent<0)return 1;
 HCRecoveryLiveSave *save=calloc(1,sizeof *save);if(!save){close(parent);return 1;}
 int result=hc_recovery_read_current_game(parent,HC_RECOVERY_PROFILES_DIRECTORY,geteuid(),&request,index,save);int closed=close(parent);
 if(result||closed){free(save);return 1;}
 char header[128];int n=snprintf(header,sizeof header,"HC-RECOVERY-CURRENT-1\n%" PRIu64 " %" PRIu64 " %s %d %zu\n",save->device,save->inode,region,save->present,save->length);
 const char footer[]="HC-RECOVERY-CURRENT-END\n";
 result=n<0||(size_t)n>=sizeof header||recovery_write(header,(size_t)n)||recovery_write(save->bytes,save->length)||recovery_write(footer,sizeof footer-1);
 free(save);return result?1:0;
}
/* Selection inspection only: evidence bytes are not validated here and this
 * response never authenticates a console or authorizes a write. */
static int inspect_save_recovery(int battery){
 const size_t maximum=185u+256u*1024u;unsigned char *frame=malloc(maximum+1);if(!frame)return 1;
 size_t used=0;int failed=0,flags=fcntl(STDIN_FILENO,F_GETFL);
 struct timespec start,now;if(clock_gettime(CLOCK_MONOTONIC,&start))failed=1;
 if(flags<0||fcntl(STDIN_FILENO,F_SETFL,flags|O_NONBLOCK))failed=1;
 while(!failed){
  if(clock_gettime(CLOCK_MONOTONIC,&now)){failed=1;break;}
  int64_t elapsed=(now.tv_sec-start.tv_sec)*1000+(now.tv_nsec-start.tv_nsec)/1000000;
  if(elapsed<0||elapsed>=HC_CLOCK_FRAME_TIMEOUT_MS){failed=1;break;}
  int64_t left=HC_CLOCK_FRAME_TIMEOUT_MS-elapsed;int wait_ms=left<3000?(int)left:3000;
  struct pollfd p={STDIN_FILENO,POLLIN|POLLHUP,0};int ready=poll(&p,1,wait_ms);if(ready<0&&errno==EINTR)continue;
  if(ready<=0||(p.revents&(POLLERR|POLLNVAL))){failed=1;break;}
  ssize_t n=read(STDIN_FILENO,frame+used,maximum+1-used);if(n<0&&(errno==EINTR||errno==EAGAIN))continue;if(n<0){failed=1;break;}if(!n)break;
  used+=(size_t)n;if(used>maximum){failed=1;break;}
 }
 HCClockRecoveryRequest request;HCRecoveryObservation observation;
 if(!failed&&(battery?hc_battery_recovery_decode(frame,used,&request):hc_clock_recovery_decode(frame,used,&request)))failed=1;
 int parent=-1;if(!failed){parent=open(HC_RECOVERY_PROFILES_DIRECTORY,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(parent<0)failed=1;}
 if(!failed&&(battery?hc_battery_recovery_inspect(parent,HC_RECOVERY_PROFILES_DIRECTORY,geteuid(),frame,used,&observation):hc_clock_recovery_inspect(parent,HC_RECOVERY_PROFILES_DIRECTORY,geteuid(),frame,used,&observation)))failed=1;
 if(parent>=0&&close(parent))failed=1;
 if(!failed){char result[128];int n=snprintf(result,sizeof result,"%s\n%s %d\nEND\n",battery?"HC-BATTERY-INSPECT-1":"HC-CLOCK-INSPECT-1",request.workspace,(int)request.original);
  if(n<0||(size_t)n>=sizeof result||recovery_write(result,(size_t)n))failed=1;}
 free(frame);return failed?1:0;
}
#endif
static int check_request(const char *directory,const char *name,int require_eof){
 HCLaunchRequest request={0};int flags=fcntl(STDIN_FILENO,F_GETFL);
 if(flags<0||fcntl(STDIN_FILENO,F_SETFL,flags|O_NONBLOCK)||hc_launch_request_receive(STDIN_FILENO,3000,&request)||(require_eof&&input_finished()))return 1;
 const char *last=strrchr(directory,'/');
 if(directory[0]!='/'||!last||strcmp(last+1,request.game))return 1;
 int dir=open(directory,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(dir<0)return 1;
 HCVerifiedLaunch rom=HC_VERIFIED_LAUNCH_INITIALIZER;int result=1;
 if(!hc_verified_rom_open(&rom,dir,name,geteuid(),request.digest)&&!hc_verified_launch_recheck(&rom)){
  static const char digits[]="0123456789abcdef";char token[33];
  for(size_t i=0;i<16;i++){token[i*2]=digits[request.session[i]>>4];token[i*2+1]=digits[request.session[i]&15];}token[32]=0;
  if(printf("HCK_PREFLIGHT_1\nGAME=%s\nROM=%s\nSESSION=%s\nEPOCH=%" PRIu64 "\nEND\nConsole launch is not enabled.\n",request.game,request.digest,token,request.epoch)>0)result=0;
 }
 if(rom.ready&&hc_verified_launch_close(&rom))result=1;if(close(dir))result=1;return result;
}
int main(int argc,char **argv){
 if(argc==2&&!strcmp(argv[1],"--check-compatibility-support"))return check_compatibility_support();
#ifdef HC_ENABLE_RECOVERY_OBSERVER
 if(argc==2&&!strcmp(argv[1],"--observe-recovery"))return observe_recovery();
 if(argc==3&&!strcmp(argv[1],"--observe-recovery-save"))return observe_recovery_save(argv[2]);
 if(argc==3&&!strcmp(argv[1],"--observe-retained-state"))return observe_retained_state(argv[2]);
#ifdef HC_ENABLE_RETAINED_IMAGE
 if(argc==3&&!strcmp(argv[1],"--observe-retained-image"))return observe_retained_image(argv[2]);
 if(argc==3&&!strcmp(argv[1],"--observe-retired-image"))return observe_retired_image(argv[2]);
#endif
#ifdef HC_ENABLE_RETAINED_TIME
 if(argc==2&&!strcmp(argv[1],"--observe-retained-time"))return observe_retained_time();
#endif
#ifdef HC_ENABLE_STATE_ARCHIVE
 if(argc==2&&!strcmp(argv[1],"--observe-state-archive"))return observe_state_archive();
#endif
#ifdef HC_ENABLE_MANAGER_INVENTORY
 if(argc==4&&!strcmp(argv[1],"--observe-manager-inventory"))return observe_manager_inventory(argv[2],argv[3]);
#endif
 if(argc==2&&!strcmp(argv[1],"--inspect-clock-recovery"))return inspect_save_recovery(0);
 if(argc==2&&!strcmp(argv[1],"--inspect-battery-recovery"))return inspect_save_recovery(1);
#endif
 if(argc>1&&!strcmp(argv[1],"--game")){
  int directory=open(HC_OBJECT_DIRECTORY,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  HCConsoleGame game=HC_CONSOLE_GAME_INITIALIZER;
  int opened=hc_console_game_open(&game,argc-1,(const char *const *)(argv+1),directory,geteuid());
  if(opened){
   if(directory>=0)(void)close(directory);
   fputs(opened==-2?"Invalid compatibility menu request.\n":"Compatibility ROM could not be verified.\n",stderr);return 2;
  }
#ifdef HC_ENABLE_SELECTED_PARENT_PREFLIGHT
  /* Read-only target preflight only. Gameplay stays disabled until the
   * production session owner and recovery path are complete. */
  if(game.command.checkpoint.have_load){
   int parent=hc_stock_selected_open_console_parent(&game,geteuid());
   if(parent<0||close(parent)){
    (void)hc_console_game_close(&game);(void)close(directory);
    fputs("Selected state directory could not be verified. Console launch is not enabled.\n",stderr);return 2;
   }
   fputs("Selected state directory verified.\n",stderr);
  }
#endif
#ifdef HC_HOST_GAME_RUNNER
  /* Explicitly host-only fixture: no production gameplay release exists. */
  extern int hc_test_entry_run(HCConsoleGame *,int,const char *const [],int);
  int host_result=hc_test_entry_run(&game,argc-1,(const char *const *)(argv+1),directory);
#endif
  int close_rom=hc_console_game_close(&game),close_directory=close(directory);
  if(close_rom||close_directory){
   fputs("Compatibility ROM verification could not be completed.\n",stderr);return 2;
  }
#ifdef HC_HOST_GAME_RUNNER
  return host_result;
#else
  fputs("Compatibility ROM verified; console launch is not enabled.\n",stderr);return 2;
#endif
 }
 if(argc==4&&!strcmp(argv[1],"--check-request"))return check_request(argv[2],argv[3],1);
 /* The caller must bound input to exactly one frame; the legacy daemon does
  * not close stdin when it has sent its declared number of bytes. */
 if(argc==4&&!strcmp(argv[1],"--check-request-framed"))return check_request(argv[2],argv[3],0);
 if(argc!=6||strcmp(argv[1],"--check-rom")||!game_ok(argv[2])||argv[3][0]!='/'){
  fputs("Offline ROM check only; console launch is not enabled.\n",stderr);return 2;
 }
 int dir=open(argv[3],O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(dir<0){fputs("Could not open the ROM folder.\n",stderr);return 1;}
 HCVerifiedLaunch rom=HC_VERIFIED_LAUNCH_INITIALIZER;int result=1;
 if(hc_verified_rom_open(&rom,dir,argv[4],geteuid(),argv[5])||hc_verified_launch_recheck(&rom))fputs("The ROM could not be verified against the supplied digest.\n",stderr);
 else{puts("ROM matches the supplied digest. Console launch is not enabled.");result=0;}
 if(rom.ready&&hc_verified_launch_close(&rom))result=1;if(close(dir))result=1;return result;
}
