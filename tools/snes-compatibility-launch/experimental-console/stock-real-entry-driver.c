#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
/* Mac-only fixture. Never compile into or use as a production console runner. */
#ifdef __arm__
#error "Host-only experiment"
#endif
#include "console-game.h"
#include "stock-game-session.h"
#include "stock-config.h"
#include "stock-runtime-bridge.h"
#include "stock-entry-finalize.h"
#include "stock-previous-save.h"
#include "stock-gameplay.h"
#include "stock-entry-start.h"
#include "size-probe-runner.h"
#include "stock-exit-owner.h"
#include "stock-reset-input.h"
#include "stock-control-session.h"
#include "stock-screenshot-capture.h"
#include "stock-retained-image.h"
#include "stock-manager-image.h"
#include "screenshot-session-names.h"
#if defined(HC_STOCK_RETAINED_TEST_HOOK) && defined(__arm__)
#error "Retained-image interruption injection is host-only."
#endif
#include "stock-state-capture.h"
#include "stock-state-seed.h"
#include "state_codec.h"
#include "stock-reset-open.h"
#include "stock-power-open.h"
#include "ram-menu-term.h"
#include "stock-session-signals.h"
#include "recovery-binding.h"
#include "save-directory-lock.h"
#include "mbedtls/sha256.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#ifdef HC_STOCK_STATE_ARCHIVE_TEST_HOOK
static HCStockStateReceipt *package_receipt;
static HCStockGameSession *package_game;
static HCConsoleRuntime *package_runtime;
static HCStockControlSession *package_control;
static HCStateBytes *package_result;
void hc_test_state_archive_hook(int stage,HCStockStateArchive *archive){
 const char *partial=getenv("HC_ENTRY_STATE_ARCHIVE_PARTIAL");
 if(partial&&stage>=1&&stage<=3&&atoi(partial)==stage)_exit(104+stage);
 if(stage==4&&getenv("HC_ENTRY_STATE_ARCHIVE_CRASH"))_exit(104);
 if(stage==4&&getenv("HC_ENTRY_STATE_ARCHIVE_TAMPER_AFTER")){
  int fd=openat(archive->parent,"state-captured",O_WRONLY|O_NOFOLLOW|O_CLOEXEC);
  if(fd<0||pwrite(fd,"X",1,0)!=1||close(fd))_exit(108);
 }
 if(stage==4&&getenv("HC_ENTRY_PACKAGE_RETAINED_STATE")){
  HCStateBytes packed=HC_STATE_BYTES_INITIALIZER;
  package_game->token[0]^=1;
  if(!hc_stock_state_archive_encode(archive,package_receipt,package_game,package_runtime,package_control,&packed)||packed.data||packed.length)_exit(109);
  package_game->token[0]^=1;
  if(getenv("HC_ENTRY_PACKAGE_OCCUPIED")){package_result->data=malloc(1);if(!package_result->data)_exit(114);package_result->data[0]=42;package_result->length=1;}
  if(getenv("HC_ENTRY_NATIVE_STATE_CONFLICT_LATE")){
   int d=open(getenv("HC_ENTRY_NATIVE_STATE_PARENT"),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(d<0)_exit(115);
   int fd=openat(d,"savestate",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
   if(fd<0||write(fd,"KEEP",4)!=4||close(fd)||close(d))_exit(116);
  }
 }
 if(stage==4)fputs("SESSION STATE RETAINED BEFORE MANAGER COMPLETION\n",stderr);
}
#endif
#ifdef HC_STOCK_RETAINED_TEST_HOOK
void hc_test_stock_retained_hook(int stage){
 if(stage==4&&getenv("HC_ENTRY_NATIVE_STATE_PARENT")){
  fputs("HC-STATE-PUBLISHED\n",stderr);
  if(getenv("HC_ENTRY_NATIVE_STATE_TAMPER")){
   int d=open(getenv("HC_ENTRY_NATIVE_STATE_PARENT"),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(d<0)_exit(117);
   int fd=openat(d,"savestate",O_WRONLY|O_NOFOLLOW|O_CLOEXEC);if(fd<0||pwrite(fd,"X",1,0)!=1||close(fd)||close(d))_exit(118);
  }
 }
#ifdef HC_STOCK_STATE_ARCHIVE_TEST_HOOK
 if(stage==3&&getenv("HC_ENTRY_PACKAGE_RETAINED_STATE")){
  if(!package_result||!package_result->data||!package_result->length)_exit(110);
  int fd=openat(package_receipt->dir,"210.state.pack",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
  if(fd<0)_exit(111);
  for(size_t pos=0;pos<package_result->length;){ssize_t n=write(fd,package_result->data+pos,package_result->length-pos);if(n<0&&errno==EINTR)continue;if(n<=0)_exit(112);pos+=(size_t)n;}
  if(fsync(fd)||close(fd))_exit(113);
  fputs("SESSION ARCHIVE PACKAGED\n",stderr);
 }
#endif
 if(stage==1&&getenv("HC_ENTRY_CRASH_AFTER_SCREENSHOT_RETAINED"))_exit(94);
 if(stage==2&&getenv("HC_ENTRY_CRASH_AFTER_RETAINED_SAVE"))_exit(95);
}
#endif
#ifdef HC_STOCK_MANAGER_TEST_HOOK
static int seed_close_fault;
int hc_test_time_seed_close(int fd){
 if(seed_close_fault==1){errno=EINTR;return -1;}
 if(seed_close_fault==2){if(close(fd))return -1;errno=EINTR;return -1;}
 return close(fd);
}
void hc_test_manager_image_hook(int stage){
 if(stage==3&&getenv("HC_ENTRY_ORDERED_MANAGER_IMAGE"))fputs("HC-IMAGE-PUBLISHED\n",stderr);
 if(stage==5&&getenv("HC_ENTRY_ORDERED_MANAGER_TIME"))fputs("HC-TIME-PUBLISHED\n",stderr);
 const char *selected=getenv("HC_ENTRY_MANAGER_IMAGE_INTERRUPT");
 if(selected&&selected[0]=='0'+stage&&!selected[1])_exit(95+stage);
}
#endif
extern char **environ;
#ifdef HC_STOCK_SELECTED_BIND_TEST_HOOK
void hc_test_selected_bind_hook(HCStockSelectedState *selected){
 if(!getenv("HC_ENTRY_SELECTED_BIND_RACE"))return;
 int fd=openat(selected->parent,"savestate",O_WRONLY|O_NOFOLLOW|O_CLOEXEC);
 if(fd<0||pwrite(fd,"X",1,0)!=1||close(fd))_exit(119);
}
#endif
#ifdef HC_STOCK_MANAGER_STATE_TEST_HOOK
void hc_test_manager_state_hook(int stage){
 const char *selected=getenv("HC_ENTRY_NATIVE_STATE_INTERRUPT");if(selected&&atoi(selected)==stage)_exit(120+stage);
}
#endif
static HCStockScreenshotCapture real_capture;
static int trace_capture_begin(void *p,HCStockSaveSession *save){int r=real_capture.begin(p,save);if(r)fprintf(stderr,"Screenshot begin failed: errno=%d\n",errno);return r;}
static int trace_capture_poll(void *p,HCStockSaveSession *save,uint64_t now){int r=real_capture.poll(p,save,now);if(r<0)fprintf(stderr,"Screenshot poll failed: errno=%d\n",errno);return r;}
#ifdef HC_TEST_POSTSPAWN_FAILURE
int hc_test_postspawn_failure(void){return getenv("HC_ENTRY_TEST_POSTSPAWN")!=NULL;}
#endif
#ifdef HC_UNPUBLISHED_ERROR_TEST_HOOK
int hc_test_unpublished_error_hook(int stage){
 static int injected;const char *requested=getenv("HC_ENTRY_RETRY_PARTIAL");
 if(!injected&&requested&&atoi(requested)==stage){injected=1;return 1;}return 0;
}
#endif
static int open_reviewed(const char *path,const char *hash,HCVerifiedLaunch *out){
 char parent[1024];if(!path||!hash||path[0]!='/'||strlen(path)>=sizeof parent)return -1;
 strcpy(parent,path);char *slash=strrchr(parent,'/');if(!slash||!slash[1])return -1;const char *name=slash+1;*slash=0;
 int dir=open(parent,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(dir<0)return -1;
 int result=hc_verified_rom_open(out,dir,name,geteuid(),hash);int saved=errno;close(dir);errno=saved;return result;
}
/* The host fixture creates a separate synthetic manager record and maps its
 * logical volatile path into disposable storage. It is not console evidence. */
static int test_manager_image_publication(HCConsoleGame *game,HCConsoleRuntime *runtime,HCStockGameSession *session,HCStockControlSession *control,HCStockScreenshotReceipt *shot,HCStockRetainedImage *retained,int stage,int argc,const char *const argv[]){
 const char *parent_path=getenv("HC_ENTRY_MANAGER_IMAGE_PARENT");if(!parent_path)return -1;
 int manager_parent=open(parent_path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(manager_parent<0||mkdirat(stage,"manager-meta",0700))return -1;
 int metadata=openat(stage,"manager-meta",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(metadata<0)return -1;
 char logical[1024],time_path[1024];
 if(snprintf(logical,sizeof logical,"/var/cache/clover/volatile/%s/suspendpoint0/state.png",session->game)>=(int)sizeof logical||
    snprintf(time_path,sizeof time_path,"/var/cache/clover/volatile/%s/suspendpoint0/state.time",session->game)>=(int)sizeof time_path)return -1;
 const char *args[64];if(argc+4>=64)return -1;for(int i=0;i<argc;i++)args[i]=argv[i];
 args[argc]="--save-screenshot-on-quit";args[argc+1]=logical;args[argc+2]="--save-time-path";args[argc+3]=time_path;
 HCConsoleGame extended=*game;if(hc_parse_compatibility_menu_command(argc+4,args,&extended.command))return -1;
 HCConsoleRuntime observed=HC_CONSOLE_RUNTIME_INITIALIZER;observed.workspace=metadata;observed.request=runtime->request;
 if(hc_console_game_prepare_manager_record(&extended,&observed,argc+4,args))return -1;
 HCStockManagerImage manager=HC_STOCK_MANAGER_IMAGE_INITIALIZER;
 observed.request.session[0]^=1;if(!hc_stock_manager_image_publish(&manager,retained,session,control,shot,&observed,&extended,manager_parent)||manager.attempted)return -1;observed.request.session[0]^=1;
 if(!hc_stock_manager_image_publish(&manager,retained,session,control,shot,&observed,&extended,stage)||manager.attempted)return -1;
 int meta=openat(metadata,"manager.meta",O_RDWR|O_NOFOLLOW|O_CLOEXEC);unsigned char marker;
 if(meta<0||pread(meta,&marker,1,0)!=1||pwrite(meta,"X",1,0)!=1)return -1;
 if(!hc_stock_manager_image_publish(&manager,retained,session,control,shot,&observed,&extended,manager_parent)||manager.attempted)return -1;
 if(pwrite(meta,&marker,1,0)!=1||close(meta)||symlinkat("missing",manager_parent,"state.png"))return -1;
 if(!hc_stock_manager_image_publish(&manager,retained,session,control,shot,&observed,&extended,manager_parent)||manager.attempted||unlinkat(manager_parent,"state.png",0))return -1;
 int occupied=openat(manager_parent,"state.png",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
 if(occupied<0||write(occupied,"KEEP",4)!=4||close(occupied))return -1;
 if(!hc_stock_manager_image_publish(&manager,retained,session,control,shot,&observed,&extended,manager_parent)||manager.attempted)return -1;
 occupied=openat(manager_parent,"state.png",O_RDONLY|O_NOFOLLOW|O_CLOEXEC);char keep[4];
 if(occupied<0||read(occupied,keep,4)!=4||memcmp(keep,"KEEP",4)||close(occupied)||unlinkat(manager_parent,"state.png",0))return -1;
 shot->image[0]^=1;
 if(!hc_stock_manager_image_publish(&manager,retained,session,control,shot,&observed,&extended,manager_parent)||manager.attempted)return -1;
 shot->image[0]^=1;
 /* A separate existing time directory cannot be authenticated by the image
  * parent's descriptor. Refuse it before writing either manager output. */
 int game_dir=openat(manager_parent,"..",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
 if(game_dir<0||mkdirat(game_dir,"other",0700)||close(game_dir)||mkdirat(stage,"manager-meta-other",0700))return -1;
 int other_metadata=openat(stage,"manager-meta-other",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(other_metadata<0)return -1;
 char other_time[1024];if(snprintf(other_time,sizeof other_time,"/var/cache/clover/volatile/%s/other/state.time",session->game)>=(int)sizeof other_time)return -1;
 args[argc+3]=other_time;HCConsoleGame other_game=*game;
 if(hc_parse_compatibility_menu_command(argc+4,args,&other_game.command))return -1;
 HCConsoleRuntime other=HC_CONSOLE_RUNTIME_INITIALIZER;other.workspace=other_metadata;other.request=runtime->request;
 if(hc_console_game_prepare_manager_record(&other_game,&other,argc+4,args)||
    !hc_stock_manager_image_publish(&manager,retained,session,control,shot,&other,&other_game,manager_parent)||manager.attempted||close(other_metadata))return -1;
 args[argc+3]=time_path;
 if(hc_stock_manager_image_publish(&manager,retained,session,control,shot,&observed,&extended,manager_parent)||
    !hc_stock_manager_image_publish(&manager,retained,session,control,shot,&observed,&extended,manager_parent))return -1;
 if(getenv("HC_ENTRY_TEST_TIME_PUBLISH")){
  HCStockManagerTime timer=HC_STOCK_MANAGER_TIME_INITIALIZER;
  HCPlaytimeInstant start={10,200000000},end={53,500000000},backward={9,0};
  if(!hc_stock_manager_time_publish(&timer,&manager,retained,session,control,shot,&observed,&extended,manager_parent,start,backward)||timer.attempted)return -1;
  observed.request.session[0]^=1;
  if(!hc_stock_manager_time_publish(&timer,&manager,retained,session,control,shot,&observed,&extended,manager_parent,start,end)||timer.attempted)return -1;
  observed.request.session[0]^=1;
  extended.command.time.have_load=1;
  if(!hc_stock_manager_time_publish(&timer,&manager,retained,session,control,shot,&observed,&extended,manager_parent,start,end)||timer.attempted)return -1;
  extended.command.time.have_load=0;
  int changed_image=openat(manager_parent,"state.png",O_RDWR|O_NOFOLLOW|O_CLOEXEC);unsigned char original;
  if(changed_image<0||pread(changed_image,&original,1,0)!=1)return -1;
  unsigned char changed=(unsigned char)(original^1);if(pwrite(changed_image,&changed,1,0)!=1)return -1;
  if(!hc_stock_manager_time_publish(&timer,&manager,retained,session,control,shot,&observed,&extended,manager_parent,start,end)||timer.attempted)return -1;
  if(pwrite(changed_image,&original,1,0)!=1||close(changed_image))return -1;
  int occupied_time=openat(manager_parent,"state.time",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
  if(occupied_time<0||write(occupied_time,"KEEP",4)!=4||close(occupied_time))return -1;
  if(!hc_stock_manager_time_publish(&timer,&manager,retained,session,control,shot,&observed,&extended,manager_parent,start,end)||timer.attempted)return -1;
  occupied_time=openat(manager_parent,"state.time",O_RDONLY|O_NOFOLLOW|O_CLOEXEC);char time_keep[4];
  if(occupied_time<0||read(occupied_time,time_keep,4)!=4||memcmp(time_keep,"KEEP",4)||close(occupied_time)||unlinkat(manager_parent,"state.time",0))return -1;
  if(hc_stock_manager_time_publish(&timer,&manager,retained,session,control,shot,&observed,&extended,manager_parent,start,end)||
     !hc_stock_manager_time_publish(&timer,&manager,retained,session,control,shot,&observed,&extended,manager_parent,start,end)||
     hc_stock_manager_time_close(&timer))return -1;
  puts("VERIFIED PLAY-TIME PUBLISHED IN HOST FIXTURE");
 }
 if(getenv("HC_ENTRY_TEST_TIME_JOURNAL")){
  char time_identity[1024],hex[33];static const char digits[]="0123456789abcdef";
  if(snprintf(time_identity,sizeof time_identity,"%s/state.time",parent_path)>=(int)sizeof time_identity)return -1;
  for(size_t i=0;i<16;i++){hex[2*i]=digits[session->token[i]>>4];hex[2*i+1]=digits[session->token[i]&15];}hex[32]=0;
  const char *workspace="checkpoint-fffffffffffffffffffffffffffffffe";
  if(hciv2_create(manager_parent,hex,workspace,"state.time",HCIV2_FINAL))return -1;
  HCSessionExpected regions[5]={{retained->target.parent,session->save.identity,0},{retained->target.parent,retained->clock,1},
   {retained->target.parent,retained->image,100},{manager_parent,manager.path,103},{manager_parent,time_identity,104}};
  HCIV2Entry entries[16];size_t count=0;
  if(hc_binding_inventory(retained->target.parent,manager.binding,session->game,session->rom.sha256,session->token,session->epoch,regions,5,3,entries,16,&count)||count!=2)return -1;
  const char *unknown="checkpoint-fffffffffffffffffffffffffffffffd";
  if(hciv2_create(manager_parent,hex,unknown,"unknown.bin",HCIV2_FINAL))return -1;
  if(!hc_binding_inventory(retained->target.parent,manager.binding,session->game,session->rom.sha256,session->token,session->epoch,regions,5,3,entries,16,&count)||
     hciv2_remove_confirmed_orphan(manager_parent,hex,unknown,"unknown.bin",HCIV2_FINAL))return -1;
  puts("TIME AND IMAGE JOURNALS RECOGNIZED TOGETHER");
 }
 if(hc_stock_manager_image_close(&manager)||close(metadata)||close(manager_parent))return -1;
 puts("MANAGER SCREENSHOT PUBLISHED IN HOST FIXTURE");return 0;
}
/* The actual request was save-only; this host-only fixture supplies a
 * separate synthetic screenshot request after the child stops. Production
 * still rejects the real menu's screenshot/time request before launch. */
static int test_ordered_manager_image_finish(HCStockGameplay *gameplay,HCConsoleGame *game,HCConsoleRuntime *runtime,HCStockGameSession *session,int stage,int argc,const char *const argv[]){
 const char *parent_path=getenv("HC_ENTRY_MANAGER_IMAGE_PARENT");if(!parent_path||!gameplay->transition||gameplay->transition->phase!=HC_EXITING)return -1;
 if(getenv("HC_ENTRY_ACTUAL_MANAGER_REQUEST")){
  int parent=open(parent_path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(parent<0)return -1;
  HCStockManagerImage image=HC_STOCK_MANAGER_IMAGE_INITIALIZER;HCStockManagerTime timer=HC_STOCK_MANAGER_TIME_INITIALIZER;
  int result=hc_stock_gameplay_finish_with_image_time(gameplay,&image,&timer,parent);
  if(result&&gameplay->phase==HC_GAMEPLAY_RECOVERY)fputs("MANAGER SESSION REQUIRES RECOVERY\n",stderr);
  if(!result)fprintf(stderr,"HC-CLOCK-START %llu %u END %llu %u\n",(unsigned long long)gameplay->clock_start.seconds,gameplay->clock_start.nanoseconds,(unsigned long long)gameplay->clock_end.seconds,gameplay->clock_end.nanoseconds);
  if(timer.attempted&&hc_stock_manager_time_close(&timer))result=-1;
  if(image.attempted&&hc_stock_manager_image_close(&image))result=-1;
  if(close(parent))result=-1;
  if(!result)puts("ORDERED MANAGER SCREENSHOT PUBLISHED IN HOST FIXTURE");
  return result;
 }
 int parent=open(parent_path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(parent<0||mkdirat(stage,"manager-meta-ordered",0700))return -1;
 int metadata=openat(stage,"manager-meta-ordered",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(metadata<0)return -1;
 char logical[1024],logical_time[1024];if(snprintf(logical,sizeof logical,"/var/cache/clover/volatile/%s/suspendpoint0/state.png",session->game)>=(int)sizeof logical)return -1;
 if(snprintf(logical_time,sizeof logical_time,"/var/cache/clover/volatile/%s/suspendpoint0/state.time",session->game)>=(int)sizeof logical_time)return -1;
 int with_time=getenv("HC_ENTRY_ORDERED_MANAGER_TIME")!=NULL,count=argc+(with_time?4:2);
 const char *args[64];if(count>=64)return -1;for(int i=0;i<argc;i++)args[i]=argv[i];args[argc]="--save-screenshot-on-quit";args[argc+1]=logical;
 if(with_time){args[argc+2]="--save-time-path";args[argc+3]=logical_time;}
 HCConsoleGame extended=*game;if(hc_parse_compatibility_menu_command(count,args,&extended.command))return -1;
 HCConsoleRuntime observed=HC_CONSOLE_RUNTIME_INITIALIZER;observed.workspace=metadata;observed.request=runtime->request;
 if(hc_console_game_prepare_manager_record(&extended,&observed,count,args))return -1;
 if(getenv("HC_ENTRY_ORDERED_IMAGE_CONFLICT")){
  int fd=openat(parent,"state.png",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
  if(fd<0||write(fd,"KEEP",4)!=4||close(fd))return -1;
 }
 if(getenv("HC_ENTRY_ORDERED_TIME_CONFLICT")){
  int fd=openat(parent,"state.time",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
  if(fd<0||write(fd,"KEEP",4)!=4||close(fd))return -1;
 }
 HCStockManagerImage image=HC_STOCK_MANAGER_IMAGE_INITIALIZER;HCStockManagerTime timer=HC_STOCK_MANAGER_TIME_INITIALIZER;
 HCConsoleGame *original_game=gameplay->entry->game;HCConsoleRuntime *original_runtime=gameplay->entry->runtime;
 gameplay->entry->game=&extended;gameplay->entry->runtime=&observed;
 int result=with_time?hc_stock_gameplay_finish_with_image_time(gameplay,&image,&timer,parent):hc_stock_gameplay_finish_with_image(gameplay,&image,parent);
 if(with_time&&!result)fprintf(stderr,"HC-CLOCK-START %llu %u END %llu %u\n",(unsigned long long)gameplay->clock_start.seconds,gameplay->clock_start.nanoseconds,(unsigned long long)gameplay->clock_end.seconds,gameplay->clock_end.nanoseconds);
 gameplay->entry->game=original_game;gameplay->entry->runtime=original_runtime;
 if(result&&gameplay->phase!=HC_GAMEPLAY_RECOVERY)return -1;
 if(timer.attempted&&hc_stock_manager_time_close(&timer))return -1;
 if(image.attempted&&hc_stock_manager_image_close(&image))return -1;
 if(close(metadata)||close(parent))return -1;
 if(!result)puts("ORDERED MANAGER SCREENSHOT PUBLISHED IN HOST FIXTURE");
 return result;
}
typedef struct {HCStockTimeSeed seed;HCConsoleRuntime runtime;HCConsoleGame game;int parent,metadata;} HCResumeFixture;
static int test_resume_prepare(HCResumeFixture *f,HCConsoleGame *game,HCConsoleRuntime *runtime,HCStockGameSession *session,int stage,int argc,const char *const argv[]){
 const char *parent_path=getenv("HC_ENTRY_MANAGER_IMAGE_PARENT");if(!f||!parent_path||argc+6>=64)return -1;
 f->parent=open(parent_path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(f->parent<0)return -1;
 if(getenv("HC_ENTRY_ACTUAL_MANAGER_REQUEST")){
  if(hc_stock_time_seed_open(&f->seed,session,runtime,game,f->parent)||f->seed.prior!=43)return -1;
  fputs("RESUME TIME CAPTURED BEFORE FRONTEND START\n",stderr);return 0;
 }
 if(mkdirat(stage,"manager-meta-resume",0700))return -1;
 f->metadata=openat(stage,"manager-meta-resume",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(f->metadata<0)return -1;
 char image[1024],load[1024],save[1024];
 if(snprintf(image,sizeof image,"/var/cache/clover/volatile/%s/suspendpoint0/state.png",session->game)>=(int)sizeof image||
    snprintf(load,sizeof load,"/var/cache/clover/volatile/%s/suspendpoint0/state.load.time",session->game)>=(int)sizeof load||
    snprintf(save,sizeof save,"/var/cache/clover/volatile/%s/suspendpoint0/state.time",session->game)>=(int)sizeof save)return -1;
 const char *args[64];for(int i=0;i<argc;i++)args[i]=argv[i];args[argc]="--save-screenshot-on-quit";args[argc+1]=image;
 args[argc+2]="--load-time-path";args[argc+3]=getenv("HC_ENTRY_RESUME_SAME_TARGET")?save:load;args[argc+4]="--save-time-path";args[argc+5]=save;
 f->game=*game;f->runtime=(HCConsoleRuntime)HC_CONSOLE_RUNTIME_INITIALIZER;f->runtime.workspace=f->metadata;f->runtime.request=runtime->request;
 if(hc_parse_compatibility_menu_command(argc+6,args,&f->game.command)||hc_console_game_prepare_manager_record(&f->game,&f->runtime,argc+6,args))return -1;
 f->runtime.request.session[0]^=1;if(!hc_stock_time_seed_open(&f->seed,session,&f->runtime,&f->game,f->parent)||f->seed.ready)return -1;f->runtime.request.session[0]^=1;
 if(!hc_stock_time_seed_open(&f->seed,session,&f->runtime,&f->game,stage)||f->seed.ready)return -1;
 if(hc_stock_time_seed_open(&f->seed,session,&f->runtime,&f->game,f->parent)||f->seed.prior!=43)return -1;
#ifdef HC_STOCK_MANAGER_TEST_HOOK
 seed_close_fault=1;if(!hc_stock_time_seed_close(&f->seed)||!f->seed.ready||f->seed.fd<3)return -1;
 seed_close_fault=0;if(hc_stock_time_seed_recheck(&f->seed,session,&f->runtime,&f->game,f->parent))return -1;
 seed_close_fault=2;if(!hc_stock_time_seed_close(&f->seed)||f->seed.ready||f->seed.fd!=-1)return -1;
 seed_close_fault=0;if(hc_stock_time_seed_open(&f->seed,session,&f->runtime,&f->game,f->parent)||f->seed.prior!=43)return -1;
#endif
 fputs("RESUME TIME CAPTURED BEFORE FRONTEND START\n",stderr);return 0;
}
static int test_resume_finish(HCStockGameplay *gameplay,HCResumeFixture *f){
 if(getenv("HC_ENTRY_SEED_BACKUP_LATE_TAMPER")){
  int fd=openat(f->seed.backup_runtime->workspace,"time-original",O_WRONLY|O_TRUNC|O_NOFOLLOW|O_CLOEXEC);if(fd<0||write(fd,"99",2)!=2||close(fd))return -1;
 }
 const char *source=f->seed.same_target?"state.time":"state.load.time";
 if(getenv("HC_ENTRY_RESUME_TAMPER")){
  int fd=openat(f->parent,source,O_WRONLY|O_TRUNC|O_NOFOLLOW|O_CLOEXEC);if(fd<0||write(fd,"99",2)!=2||close(fd))return -1;
 }
 if(getenv("HC_ENTRY_RESUME_SWAP")){
  if(renameat(f->parent,source,f->parent,"state.original.time"))return -1;
  int fd=openat(f->parent,source,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0||write(fd,"43",2)!=2||close(fd))return -1;
 }
 if(getenv("HC_ENTRY_RESUME_TARGET_CONFLICT")){
  int fd=openat(f->parent,"state.time",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0||write(fd,"KEEP",4)!=4||close(fd))return -1;
 }
 HCStockManagerImage image=HC_STOCK_MANAGER_IMAGE_INITIALIZER;HCStockManagerTime timer=HC_STOCK_MANAGER_TIME_INITIALIZER;
 HCConsoleGame *original_game=gameplay->entry->game;HCConsoleRuntime *original_runtime=gameplay->entry->runtime;
 if(!getenv("HC_ENTRY_ACTUAL_MANAGER_REQUEST")){gameplay->entry->game=&f->game;gameplay->entry->runtime=&f->runtime;}
 int result=hc_stock_gameplay_finish_with_resumed_time(gameplay,&image,&timer,&f->seed,f->parent);
 if(!result)fprintf(stderr,"HC-CLOCK-START %llu %u END %llu %u\n",(unsigned long long)gameplay->clock_start.seconds,gameplay->clock_start.nanoseconds,(unsigned long long)gameplay->clock_end.seconds,gameplay->clock_end.nanoseconds);
 gameplay->entry->game=original_game;gameplay->entry->runtime=original_runtime;
 if(timer.attempted&&hc_stock_manager_time_close(&timer))return -1;
 if(image.attempted&&hc_stock_manager_image_close(&image))return -1;
 if(hc_stock_time_seed_close(&f->seed)||(f->metadata>=0&&close(f->metadata))||close(f->parent))return -1;
 if(!result)puts("ORDERED MANAGER SCREENSHOT PUBLISHED IN HOST FIXTURE");return result;
}
int hc_test_entry_run(HCConsoleGame *game,int argc,const char *const argv[],int object_fd){
 if(getenv("HC_ENTRY_MANAGER_SIGNAL")){
  /* Match the blocked/ignored SIGTERM inheritance observed in the real menu.
   * The trial installer must restore delivery before a game is spawned. */
  struct sigaction inherited={0};sigset_t blocked;
  inherited.sa_handler=SIG_IGN;
  if(sigemptyset(&inherited.sa_mask)||sigaction(SIGTERM,&inherited,NULL)||
     sigemptyset(&blocked)||sigaddset(&blocked,SIGTERM)||sigprocmask(SIG_BLOCK,&blocked,NULL)||
     hc_stock_session_signals_install())return 3;
 }
 /* Mac-only fixture: alter the incoming manager title after game open to
  * verify that changed requests are rejected before creating save records. */
 const char *const *prepare_argv=argv;const char *altered_argv[65];
 if(getenv("HC_ENTRY_TEST_STALE_ARGS")){
  if(argc<=0||argc>64)return 3;int changed=0;
  for(int i=0;i<argc;i++)altered_argv[i]=argv[i];altered_argv[argc]=NULL;
  for(int i=0;i+1<argc;i++)if(!strcmp(altered_argv[i],"--title-code")){altered_argv[i+1]="CLV-U-ZZZZZ";changed=1;break;}
  if(!changed)return 3;prepare_argv=altered_argv;
 }
 /* Refuse stale or unsupported requests before allocating a workspace. */
 int actual_request=getenv("HC_ENTRY_ACTUAL_MANAGER_REQUEST")!=NULL;
 if(getenv("HC_ENTRY_GAMEPLAY_OWNER")&&(actual_request?hc_stock_entry_validate_manager_outputs(game,argc,prepare_argv):hc_stock_entry_validate_save_only(game,argc,prepare_argv))){perror("prepare game session");return 3;}
 (void)object_fd;const char *root=getenv("HC_ENTRY_ROOT"),*program=getenv("HC_ENTRY_FRONTEND"),*corepath=getenv("HC_ENTRY_CORE"),*configpath=getenv("HC_ENTRY_CONFIG");
 if(!root||!program||!corepath||!configpath)return 2;
 const char *probe_path=getenv("HC_ENTRY_PROBE");if(!probe_path)return 2;
 char profiles[1024],savepath[1024],stagepath[1024];
 const char *fixture_profiles=getenv("HC_ENTRY_CURRENT_PROFILES");
 const char *stage_component=getenv("HC_ENTRY_STAGE");if(!stage_component)stage_component="stage";
 if(strchr(stage_component,'/')||!strcmp(stage_component,".")||!strcmp(stage_component,".."))return 2;
 if((fixture_profiles?snprintf(profiles,sizeof profiles,"%s",fixture_profiles):snprintf(profiles,sizeof profiles,"%s/profiles",root))<=0||snprintf(savepath,sizeof savepath,"%s/%s/hakchi/%s/%s",profiles,game->command.game,HC_COMPATIBILITY_ENGINE_ID,game->command.digest)<=0||snprintf(stagepath,sizeof stagepath,"%s/%s",root,stage_component)<=0)return 2;
 int parent=open(savepath,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC),stage=open(stagepath,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(parent<0||stage<0)return 2;
 int rootfd=open(root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(rootfd<0)return 2;
 int sessionfd=hc_console_runtime_open_session_parent(parent,geteuid(),1);if(sessionfd<0)return 2;
 HCVerifiedLaunch frontend=HC_VERIFIED_LAUNCH_INITIALIZER,core=HC_VERIFIED_LAUNCH_INITIALIZER,config=HC_VERIFIED_LAUNCH_INITIALIZER,probe=HC_VERIFIED_LAUNCH_INITIALIZER;
 int screenshot_mode=getenv("HC_ENTRY_MANAGER_SCREENSHOT")!=NULL;
 int state_mode=getenv("HC_ENTRY_MANAGER_STATE")!=NULL;
 const char *fixture_seed=getenv("HC_ENTRY_STATE_SEED");int autoload=fixture_seed!=NULL||getenv("HC_ENTRY_MISSING_AUTO")!=NULL||getenv("HC_ENTRY_SELECTED_STATE_PARENT")!=NULL;
 if(state_mode&&!screenshot_mode)return 3;
 /* Only this host-only fault injection changes the installed policy. */
 if(screenshot_mode&&getenv("HC_ENTRY_UNSAFE_SCREENSHOT_SIGPIPE")){struct sigaction pipe_action={0};pipe_action.sa_handler=SIG_DFL;if(sigemptyset(&pipe_action.sa_mask)||sigaction(SIGPIPE,&pipe_action,NULL))return 3;}
 int shot_dir=-1,receipt_read=-1,receipt_write=-1;
 HCStockScreenshotReceipt shot=HC_STOCK_SCREENSHOT_RECEIPT_INITIALIZER;
 HCStockRetainedImage retained_image=HC_STOCK_RETAINED_IMAGE_INITIALIZER;
 HCStockScreenshotCapture capture={0};
 if(screenshot_mode){shot_dir=openat(stage,"shots",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(shot_dir<0)return 3;}
 if(open_reviewed(program,getenv("HC_ENTRY_FRONTEND_SHA"),&frontend)||open_reviewed(corepath,getenv("HC_ENTRY_CORE_SHA"),&core)||(screenshot_mode?hc_stock_config_create_screenshot(&config,stage,stagepath,autoload):(getenv("HC_ENTRY_CREATE_CONFIG")?hc_stock_config_create(&config,stage,stagepath,autoload):open_reviewed(configpath,getenv("HC_ENTRY_CONFIG_SHA"),&config)))||open_reviewed(probe_path,getenv("HC_ENTRY_PROBE_SHA"),&probe))return 3;
 HCSizeProbe size_probe=HC_SIZE_PROBE_INITIALIZER;size_t detected=0;int probe_result=0;
 struct timespec probe_delay={0,10000000};
 if(hc_size_probe_start(&size_probe,&probe,probe_path,&core,corepath,&game->rom,stagepath)){
  if(size_probe.pid>0){(void)hc_size_probe_cancel(&size_probe);while(hc_size_probe_poll(&size_probe,&detected)==0)nanosleep(&probe_delay,NULL);}
  return 3;
 }
 for(int i=0;i<1000&&!probe_result;i++){probe_result=hc_size_probe_poll(&size_probe,&detected);if(!probe_result&&size_probe.failed)break;if(!probe_result)nanosleep(&probe_delay,NULL);}
 if(!probe_result){(void)hc_size_probe_cancel(&size_probe);while(hc_size_probe_poll(&size_probe,&detected)==0)nanosleep(&probe_delay,NULL);return 3;}
 if(probe_result!=1||detected>131072){if(size_probe.reason==HC_SIZE_PROBE_CLOCK_REQUIRED)fputs("This game needs clock-save support that is not ready yet.\n",stderr);return 3;}
 /* The existing no-SRAM session keeps a nominal empty stage, never published. */
 size_t save_size=detected?detected:32768; /* used by the host assertions */
 HCConsoleRuntime runtime=HC_CONSOLE_RUNTIME_INITIALIZER;HCConsoleSupervisor supervisor=HC_CONSOLE_SUPERVISOR_INITIALIZER;
 const char *reviewed_input=getenv("HC_ENTRY_REQUEST_INPUT");
 if(reviewed_input&&reviewed_input[0]){
  int f=open(reviewed_input,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);unsigned char wire[HC_LAUNCH_REQUEST_SIZE+1];HCLaunchRequest request;
  if(f<0)return 3;ssize_t n=read(f,wire,sizeof wire);int closed=close(f);
  if(n!=HC_LAUNCH_REQUEST_SIZE||closed||hc_launch_request_decode(wire,(size_t)n,&request)||
     hc_console_runtime_prepare_bound(&runtime,sessionfd,geteuid(),&request,game->command.game,game->command.digest))return 3;
 }else if(getenv("HC_ENTRY_RUNTIME_LOCK")){
  HCGameSavePaths paths;
  if(hc_launch_isolated_save_paths_at_root(argc-4,argv+4,game->command.game,game->command.digest,profiles,&paths))return 3;
  HCConsoleStartSpec review={.uid=geteuid(),.game=game->command.game,.digest=game->command.digest,.rom_name=game->rom.name,.profiles_root=profiles,
   .verified_rom=&game->rom,.manager_argc=argc-4,.manager_argv=argv+4,.expected_sram=paths.sram,.expected_rtc=paths.rtc};
  if(hc_console_runtime_prepare_game(&runtime,&review)){perror("prepare runtime lock");return 3;}
 }else if(hc_console_runtime_prepare(&runtime,sessionfd,geteuid(),game->command.game,game->command.digest))return 3;
 HCStockGameSession session=HC_STOCK_GAME_SESSION_INITIALIZER;
 if(hc_stock_game_prepare_detected(&session,&runtime,game,argc,argv,profiles,parent,stage,"210.srm",&size_probe,&frontend)==0)return 3;
 HCVerifiedLaunch *held_rom=size_probe.rom;size_probe.rom=&core;
 if(hc_stock_game_prepare_detected(&session,&runtime,game,argc,argv,profiles,parent,stage,"210.srm",&size_probe,&core)==0)return 3;
 size_probe.rom=held_rom;
 HCStockEntryLaunch launch=HC_STOCK_ENTRY_LAUNCH_INITIALIZER;
 int prepare_result=actual_request?hc_stock_entry_prepare_manager_outputs(&launch,&session,&runtime,game,argc,prepare_argv,profiles,parent,stage,"210.srm",&size_probe,&core):getenv("HC_ENTRY_GAMEPLAY_OWNER")?hc_stock_entry_prepare_save_only(&launch,&session,&runtime,game,argc,prepare_argv,profiles,parent,stage,"210.srm",&size_probe,&core):hc_stock_entry_prepare(&launch,&session,&runtime,game,argc,prepare_argv,profiles,parent,stage,"210.srm",&size_probe,&core);
 if(prepare_result){perror("prepare game session");return 3;}
 if(getenv("HC_ENTRY_RUNTIME_LOCK")){if(runtime.save_lock<3||session.save_lock<3)return 3;puts("RUNTIME LOCK SHARED");}
 int competing_lock=hc_save_directory_lock(parent,geteuid());if(competing_lock>=0){close(competing_lock);fputs("game save lock did not exclude a second owner\n",stderr);return 3;}if(errno!=EWOULDBLOCK&&errno!=EAGAIN)return 3;
 /* A detected size cannot be reused or paired with another core. */
 if(hc_stock_game_prepare_detected(&session,&runtime,game,argc,argv,profiles,parent,stage,"210.srm",&size_probe,&core)==0)return 3;
 if(hc_verified_launch_close(&probe))return 3;
 char initial_core_digit=session.detected_core_sha[0];session.detected_core_sha[0]=initial_core_digit=='a'?'b':'a';
 struct stat existing_stage;int stage_was_absent=fstatat(stage,"210.srm",&existing_stage,AT_SYMLINK_NOFOLLOW)!=0&&errno==ENOENT;
 if(hc_stock_game_start_seeded_reviewed(&session,210,&frontend,program,&core,corepath,&config,configpath,0,environ)==0)return 3;
 if(stage_was_absent&&(!fstatat(stage,"210.srm",&existing_stage,AT_SYMLINK_NOFOLLOW)||errno!=ENOENT)){fputs("mismatched core seeded save\n",stderr);return 3;}
 session.detected_core_sha[0]=initial_core_digit;
 if(hc_stock_game_start_seeded_reviewed(&session,210,&frontend,program,&core,corepath,&config,"/missing/config",0,environ)==0)return 3;
 if(hc_stock_game_start_seeded_reviewed(&session,211,&frontend,program,&core,corepath,&config,configpath,0,environ)==0)return 3;
 if(stage_was_absent&&(!fstatat(stage,"210.srm",&existing_stage,AT_SYMLINK_NOFOLLOW)||errno!=ENOENT)){fputs("invalid config or target seeded save\n",stderr);return 3;}
 struct sigaction original_child_action,ignored_child_action={0};ignored_child_action.sa_handler=SIG_IGN;sigemptyset(&ignored_child_action.sa_mask);
 if(sigaction(SIGCHLD,&ignored_child_action,&original_child_action))return 3;
 int bad_child_policy=hc_stock_game_start_seeded_reviewed(&session,210,&frontend,program,&core,corepath,&config,configpath,0,environ);
 if(sigaction(SIGCHLD,&original_child_action,NULL))return 3;
 if(bad_child_policy==0)return 3;
 if(stage_was_absent&&(!fstatat(stage,"210.srm",&existing_stage,AT_SYMLINK_NOFOLLOW)||errno!=ENOENT)){fputs("auto-reaped child policy seeded save\n",stderr);return 3;}
 int occupied=dup2(rootfd,210);if(occupied!=210)return 3;
 if(hc_stock_game_start_seeded_reviewed(&session,210,&frontend,program,&core,corepath,&config,configpath,0,environ)==0)return 3;
 if(close(occupied))return 3;
 if(stage_was_absent&&(!fstatat(stage,"210.srm",&existing_stage,AT_SYMLINK_NOFOLLOW)||errno!=ENOENT)){fputs("occupied target seeded save\n",stderr);return 3;}
 char *bad_environment[]={(char *)"HC_STOCK_SAVE_REPORT=0",NULL};
 if(hc_stock_game_start_seeded_reviewed(&session,210,&frontend,program,&core,corepath,&config,configpath,0,bad_environment)==0)return 3;
 if(stage_was_absent&&(!fstatat(stage,"210.srm",&existing_stage,AT_SYMLINK_NOFOLLOW)||errno!=ENOENT)){fputs("invalid environment seeded save\n",stderr);return 3;}
 if(memcmp(session.token,runtime.request.session,16)||session.epoch!=runtime.request.epoch)return 3;
 /* Host device discovery is shimmed; a real console must independently
  * authenticate these devices and the physical switch state. Both input
  * streams are acquired before any emulator or save seed is started. */
 int reset_pipe[2],power_pipe[2];if(pipe(reset_pipe)||pipe(power_pipe))return 6;
 int reset_flags=fcntl(reset_pipe[0],F_GETFL),power_flags=fcntl(power_pipe[0],F_GETFL);
 if(reset_flags<0||power_flags<0||fcntl(reset_pipe[0],F_SETFL,reset_flags|O_NONBLOCK)||fcntl(power_pipe[0],F_SETFL,power_flags|O_NONBLOCK))return 6;
 extern void hc_test_devices(int);extern void hc_test_device_fd_base(int);
 errno=0;if(fcntl(183,F_GETFD)!=-1||errno!=EBADF||dup2(reset_pipe[0],183)!=183||close(reset_pipe[0]))return 6;reset_pipe[0]=183;
 errno=0;if(fcntl(182,F_GETFD)!=-1||errno!=EBADF||dup2(power_pipe[0],182)!=182||close(power_pipe[0]))return 6;power_pipe[0]=182;
 hc_test_devices(11);hc_test_device_fd_base(180);
 HCStockOpenedReset reset=HC_STOCK_OPENED_RESET_INITIALIZER;HCStockOpenedPower power=HC_STOCK_OPENED_POWER_INITIALIZER;
 int manager_signal=getenv("HC_ENTRY_MANAGER_SIGNAL")!=NULL;
 if((!manager_signal&&hc_stock_reset_open_named(&reset,10,0,"sunxi-keyboard",115))||hc_stock_power_open_named(&power,10,0,"sunxi-knob",116,0))return 6;
 /* A launch without both controls must not seed a save. */
 if(hc_stock_entry_start(&launch,&session,&runtime,game,210,&frontend,program,&core,corepath,&config,configpath,0,environ)==0)return 3;
 HCStockControlSession control=HC_STOCK_CONTROL_SESSION_INITIALIZER;
 if((manager_signal?hc_stock_control_prepare_manager(&control,&session.save,hc_ram_menu_term_requested):hc_stock_control_prepare(&control,&reset.input,&session.save))||hc_stock_control_attach_power(&control,&power.input)||hc_stock_entry_bind_controls(&launch,&control))return 6;
 if(manager_signal)fputs("MANAGER RESET WITHOUT PHYSICAL INPUT\n",stderr);
 /* The shared entry must refuse a different live session before seeding SRAM. */
 session.token[0]^=1;
 if(hc_stock_entry_start(&launch,&session,&runtime,game,210,&frontend,program,&core,corepath,&config,configpath,0,environ)==0)return 3;
 session.token[0]^=1;
 if(stage_was_absent&&(!fstatat(stage,"210.srm",&existing_stage,AT_SYMLINK_NOFOLLOW)||errno!=ENOENT)){fputs("wrong session seeded save\n",stderr);return 3;}
 if(screenshot_mode&&hc_stock_screenshot_bind_session(&session,&control,&shot,&capture,shot_dir,&receipt_read,&receipt_write))return 6;
 if(screenshot_mode){real_capture=capture;capture.begin=trace_capture_begin;capture.poll=trace_capture_poll;}
 HCStockStateReceipt state=HC_STOCK_STATE_RECEIPT_INITIALIZER;
 HCStockStateArchive archive=HC_STOCK_STATE_ARCHIVE_INITIALIZER;
 HCStateBytes state_package=HC_STATE_BYTES_INITIALIZER;
 HCStockManagerState native_state=HC_STOCK_MANAGER_STATE_INITIALIZER;int native_state_parent=-1;
 HCStockSelectedState selected_state=HC_STOCK_SELECTED_STATE_INITIALIZER;int selected_parent=-1,prior_profiles=-1;
 HCStockScreenshotCapture state_capture={0};
 if(state_mode){
  if(hc_stock_state_receipt_init(&state,&session,receipt_read,stage,"210.state"))return 6;
  state_capture=hc_stock_state_receipt_capture(&state);
  if(hc_stock_control_attach_state(&control,&state_capture))return 6;
 }
 if(fixture_seed){
  /* The fixture supplies test-owned compressed bytes. A real caller must
   * authenticate the saved-state provenance and its selected manager path. */
  struct stat st;int fd=open(fixture_seed,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);if(fd<0||fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_size<=0||st.st_size>17*1024*1024)return 6;
  size_t length=(size_t)st.st_size;unsigned char *bytes=malloc(length);if(!bytes)return 6;
  size_t pos=0;while(pos<length){ssize_t n=read(fd,bytes+pos,length-pos);if(n<0&&errno==EINTR)continue;if(n<=0){free(bytes);close(fd);return 6;}pos+=(size_t)n;}
  int closed=close(fd),seeded=hc_stock_state_seed(&session,game->command.game,game->command.digest,bytes,length);free(bytes);
  if(closed||seeded)return 6;puts("SESSION AUTOLOAD STATE SEEDED");
  if(getenv("HC_ENTRY_TAMPER_AUTO")){
   int corrupt=openat(stage,"210.state.auto",O_RDWR|O_NOFOLLOW|O_CLOEXEC);unsigned char byte;
   if(corrupt<0||pread(corrupt,&byte,1,0)!=1)return 6;byte^=1;
   if(pwrite(corrupt,&byte,1,0)!=1||close(corrupt))return 6;
  }
 }
 if(getenv("HC_ENTRY_SELECTED_STATE_PARENT")){
  const char *rootpath=getenv("HC_ENTRY_PRIOR_STATE_PROFILES"),*framepath=getenv("HC_ENTRY_PRIOR_STATE_FRAME");
  unsigned char wire[HC_LAUNCH_REQUEST_SIZE];HCLaunchRequest prior;
  if(!rootpath||(!framepath&&!getenv("HC_ENTRY_SELECTED_DISCOVER")))return 6;
  if(getenv("HC_ENTRY_SELECTED_DISCOVER")){
   selected_parent=hc_stock_selected_open_console_parent(game,geteuid());
  }else selected_parent=open(getenv("HC_ENTRY_SELECTED_STATE_PARENT"),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  prior_profiles=open(rootpath,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  if(selected_parent<0||prior_profiles<0)return 6;
  if(getenv("HC_ENTRY_SELECTED_DISCOVER")){
   HCLaunchRequest sentinel;memset(&sentinel,0xa5,sizeof sentinel);prior=sentinel;
   if(!hc_stock_selected_state_identify(&session,&runtime,game,selected_parent,prior_profiles,"/missing/profiles",&prior)||memcmp(&prior,&sentinel,sizeof prior))return 6;
  }else{
   int framefd=open(framepath,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(framefd<0)return 6;
   ssize_t n=pread(framefd,wire,sizeof wire,8);int closed=close(framefd);
   if(n!=(ssize_t)sizeof wire||closed||hc_launch_request_decode(wire,sizeof wire,&prior))return 6;
   if(getenv("HC_ENTRY_SELECTED_WRONG_PRIOR"))prior.game[10]=prior.game[10]=='Z'?'Y':'Z';
  }
  if(!getenv("HC_ENTRY_SELECTED_DISCOVER")&&hc_stock_selected_state_prepare(&selected_state,&session,&runtime,game,selected_parent,prior_profiles,rootpath,&prior))return 6;
  if(!getenv("HC_ENTRY_SELECTED_DISCOVER")){puts("SESSION MANAGER-SELECTED STATE VERIFIED");puts("SESSION AUTOLOAD STATE SEEDED");}
 }
 if(getenv("HC_ENTRY_UNBOUND_SCREENSHOT"))control.screenshot=NULL;
 HCStockPrevious captured_previous=HC_STOCK_PREVIOUS_INITIALIZER;HCStockGameplay gameplay=HC_STOCK_GAMEPLAY_INITIALIZER;
 HCResumeFixture resume={.seed=HC_STOCK_TIME_SEED_INITIALIZER,.runtime=HC_CONSOLE_RUNTIME_INITIALIZER,.game=HC_CONSOLE_GAME_INITIALIZER,.parent=-1,.metadata=-1};
 if(getenv("HC_ENTRY_RESUMED_TIME")&&test_resume_prepare(&resume,game,&runtime,&session,stage,argc,argv))return 3;
 int use_gameplay=getenv("HC_ENTRY_GAMEPLAY_OWNER")!=NULL;
 HCTransition manager_transition={game->command.manager.wait_fd,game->command.manager.start_fd,game->command.manager.finish_fd,HC_INITIAL};
 if(use_gameplay){
  if(actual_request?hc_stock_gameplay_prepare_manager_outputs(&gameplay,&launch):hc_stock_gameplay_prepare(&gameplay,&launch)){perror("prepare gameplay");return 3;}
  if(getenv("HC_ENTRY_PACKAGE_RETAINED_STATE")&&!hc_stock_gameplay_bind_state_package(&gameplay,&state_package))return 3;
  if(getenv("HC_ENTRY_RETAIN_STATE")&&hc_stock_gameplay_bind_state_archive(&gameplay,&state,&archive))return 3;
  if(getenv("HC_ENTRY_PACKAGE_RETAINED_STATE")){
   state_package.length=1;if(!hc_stock_gameplay_bind_state_package(&gameplay,&state_package))return 3;state_package.length=0;
   if(hc_stock_gameplay_bind_state_package(&gameplay,&state_package)||!hc_stock_gameplay_bind_state_package(&gameplay,&state_package))return 3;
  }
  if(getenv("HC_ENTRY_NATIVE_STATE_PARENT")){
   native_state_parent=open(getenv("HC_ENTRY_NATIVE_STATE_PARENT"),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
   if(native_state_parent<0||!hc_stock_gameplay_bind_manager_state(&gameplay,&native_state,stage))return 3;
   runtime.request.session[0]^=1;
   if(!hc_stock_gameplay_bind_manager_state(&gameplay,&native_state,native_state_parent))return 3;
   runtime.request.session[0]^=1;
   if(hc_stock_gameplay_bind_manager_state(&gameplay,&native_state,native_state_parent)||!hc_stock_gameplay_bind_manager_state(&gameplay,&native_state,native_state_parent))return 3;
  }
  if(getenv("HC_ENTRY_SELECTED_DISCOVER")){
   HCLaunchRequest discovered,sentinel;memset(&sentinel,0xa5,sizeof sentinel);discovered=sentinel;
   int r=hc_stock_gameplay_discover_selected_state(&gameplay,&selected_state,selected_parent,prior_profiles,getenv("HC_ENTRY_PRIOR_STATE_PROFILES"),&discovered);
   if(r){int saved=errno;if(memcmp(&discovered,&sentinel,sizeof discovered))return 6;
    if(getenv("HC_ENTRY_SELECTED_BIND_RACE")){if(r!=-2||gameplay.phase!=HC_GAMEPLAY_RECOVERY||!selected_state.ready)return 6;fputs("STAGED STATE RETAINED FOR RECOVERY\n",stderr);}
    errno=saved;perror("identify prior session");return 6;}
   puts("PRIOR SESSION DISCOVERED BY STATE");puts("SESSION MANAGER-SELECTED STATE VERIFIED");puts("SESSION AUTOLOAD STATE SEEDED");
  }else if(selected_state.ready&&(hc_stock_gameplay_bind_selected_state(&gameplay,&selected_state)||!hc_stock_gameplay_bind_selected_state(&gameplay,&selected_state)))return 3;
#ifdef HC_STOCK_STATE_ARCHIVE_TEST_HOOK
  package_receipt=&state;package_game=&session;package_runtime=&runtime;package_control=&control;package_result=&state_package;
#endif
  if(getenv("HC_ENTRY_ORDERED_MANAGER_TIME")&&hc_stock_gameplay_enable_time(&gameplay))return 3;
  if(getenv("HC_ENTRY_RESUMED_TIME")){
   if(getenv("HC_ENTRY_SEED_BACKUP_CONFLICT")){
    int fd=openat(runtime.workspace,"time-original",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0||write(fd,"KEEP",4)!=4||close(fd))return 3;
   }
   if(hc_stock_gameplay_bind_time_seed(&gameplay,&resume.seed))return 3;
   int backup=openat(runtime.workspace,"time-original",O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);unsigned char bytes[21];
   if(backup<0||read(backup,bytes,resume.seed.original_length)!=(ssize_t)resume.seed.original_length||memcmp(bytes,resume.seed.original,resume.seed.original_length)||close(backup))return 3;
   fputs("RESUME TIME RETAINED IN SESSION BEFORE START\n",stderr);
  }
  if(getenv("HC_ENTRY_RETAIN_SCREENSHOT")){
   if(hc_stock_gameplay_bind_retained_image(&gameplay,&retained_image,&shot)||!hc_stock_gameplay_bind_retained_image(&gameplay,&retained_image,&shot))return 3;
  }
  if(getenv("HC_ENTRY_MANAGER_TRANSITIONS")&&hc_stock_gameplay_bind_transition(&gameplay,&manager_transition)){perror("bind simulated manager");return 3;}
 }
 else if(getenv("HC_ENTRY_CAPTURE_PRIOR")&&hc_stock_previous_capture(&captured_previous,&session)){perror("capture previous save");return 3;}
 char token_env[64]="HC_TEST_SESSION_HEX=",home_env[1100],docs_env[1100];
 static const char hex[]="0123456789abcdef";size_t token_offset=strlen(token_env);
 for(size_t i=0;i<16;i++){token_env[token_offset+i*2]=hex[session.token[i]>>4];token_env[token_offset+i*2+1]=hex[session.token[i]&15];}token_env[token_offset+32]=0;
 if(snprintf(home_env,sizeof home_env,"HOME=%s",stagepath)>=(int)sizeof home_env||snprintf(docs_env,sizeof docs_env,"HC_TEST_DOCUMENTS_DIR=%s",stagepath)>=(int)sizeof docs_env)return 3;
 char *screenshot_env[]={(char *)"PATH=/usr/bin:/bin",home_env,docs_env,(char *)"LC_ALL=C",(char *)"HC_STOCK_SAVE_REPORT=1",(char *)"HC_TEST_RECEIPT_FD=213",(char *)"HC_TEST_STATE_FD=213",token_env,NULL};
 HCStockLaunchSpec spec={.target=210,.program=&frontend,.program_path=program,.core=&core,.core_path=corepath,.config=&config,.config_path=configpath,.autoload=autoload,.envp=screenshot_mode?screenshot_env:environ};
 if(getenv("HC_ENTRY_SELECTED_TAMPER_BEFORE")){
  int fd=openat(selected_parent,"savestate",O_WRONLY|O_NOFOLLOW|O_CLOEXEC);if(fd<0||pwrite(fd,"X",1,0)!=1||close(fd))return 3;
 }
 if(getenv("HC_ENTRY_RESUME_EARLY_TAMPER")){
  int fd=openat(resume.parent,resume.seed.same_target?"state.time":"state.load.time",O_WRONLY|O_TRUNC|O_NOFOLLOW|O_CLOEXEC);if(fd<0||write(fd,"99",2)!=2||close(fd))return 3;
 }
 if(getenv("HC_ENTRY_SEED_BACKUP_EARLY_TAMPER")){
  int fd=openat(runtime.workspace,"time-original",O_WRONLY|O_TRUNC|O_NOFOLLOW|O_CLOEXEC);if(fd<0||write(fd,"99",2)!=2||close(fd))return 3;
 }
 if(getenv("HC_ENTRY_TAMPER_ACTUAL_MANAGER_RECORD")){
  int fd=openat(runtime.workspace,"manager.meta",O_WRONLY|O_NOFOLLOW|O_CLOEXEC);
  if(fd<0||pwrite(fd,"X",1,0)!=1||close(fd))return 3;
 }
 if(getenv("HC_ENTRY_MANAGER_SIGNAL_EARLY")){
  if(!manager_signal||raise(SIGTERM)||!hc_ram_menu_term_requested())return 6;
  fputs("EARLY MANAGER RESET OBSERVED\n",stderr);
 }
 int launched=use_gameplay?hc_stock_gameplay_start(&gameplay,&spec):hc_stock_entry_start(&launch,&session,&runtime,game,210,&frontend,program,&core,corepath,&config,configpath,0,environ);
 if(launched){
  int saved=errno;struct timespec delay={0,10000000},stamp;int status;
  if(session.save.child_wait_unknown||session.save.child.reaped_pending){
   fputs("failed-start child ownership uncertain; session quarantined\n",stderr);for(;;)pause();
  }
  if(session.save.child.pid>1){
   for(;;){
    if(!clock_gettime(CLOCK_MONOTONIC,&stamp)&&stamp.tv_sec>=0&&stamp.tv_nsec>=0&&stamp.tv_nsec<1000000000L&&
       (uint64_t)stamp.tv_sec<=(UINT64_MAX-999)/1000){
     uint64_t now=(uint64_t)stamp.tv_sec*1000+(uint64_t)stamp.tv_nsec/1000000;
     int result=use_gameplay?hc_stock_gameplay_poll(&gameplay,now,&status):hc_stock_entry_failed_start_poll(&launch,now,&status);
     if(result==1||(use_gameplay&&result<0&&gameplay.phase==HC_GAMEPLAY_FAILED&&session.save.child.pid==-1&&!session.save.child.reaped_pending&&!session.save.child_wait_unknown)){
      if(use_gameplay)fputs("GAMEPLAY OWNER ABORTED\n",stderr);
      fputs("FAILED START CHILD REAPED\n",stderr);break;
     }
     if(result<0){fputs("failed-start child ownership uncertain; session quarantined\n",stderr);for(;;)pause();}
    }
    nanosleep(&delay,NULL);
   }
  }
  if(getenv("HC_ENTRY_RUNTIME_LOCK")){
   int competing=hc_save_directory_lock(parent,geteuid());if(competing>=0){close(competing);return 9;}
   fputs("RUNTIME LOCK RETAINED THROUGH REAP\n",stderr);
  }
  errno=saved;perror("start game session");return 4;
 }
 if(state_mode&&getenv("HC_ENTRY_STATE_CONFLICT")){
  int fd=openat(stage,"210.state",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
  if(fd<0||write(fd,"conflict",8)!=8||close(fd))return 3;
 }
 struct timespec delay={0,10000000},stamp;int status=0;
 if(getenv("HC_ENTRY_DISCONNECT_POWER")){if(close(power_pipe[1]))return 6;power_pipe[1]=-1;}
 if(getenv("HC_ENTRY_DISCONNECT_RESET")){if(close(reset_pipe[1]))return 6;reset_pipe[1]=-1;}
 for(int i=0;i<300;i++){
  if(clock_gettime(CLOCK_MONOTONIC,&stamp))return 5;
  uint64_t tick=(uint64_t)stamp.tv_sec*1000u+(uint64_t)stamp.tv_nsec/1000000u;
  if((use_gameplay?hc_stock_gameplay_poll(&gameplay,tick,&status):hc_stock_control_step(&control,tick,&status))!=0){
   if((getenv("HC_ENTRY_DISCONNECT_RESET")||getenv("HC_ENTRY_DISCONNECT_POWER"))&&(session.save.phase==HC_STOCK_REAPED_CLEAN||session.save.phase==HC_STOCK_REAPED_NO_SRAM||hc_stock_game_publish_stage(&session)==0))return 9;
   return 5;
  }nanosleep(&delay,NULL);
 }
 if(getenv("HC_ENTRY_TEST_ORPHAN_LOCK")){
  if(close(session.save_lock))return 6;session.save_lock=-1;session.save.cooperative_lock=-1;
  /* Fixture only: simulate loss of both supervisor-held lock descriptors. */
  if(getenv("HC_ENTRY_RUNTIME_LOCK")){if(runtime.save_lock<3||close(runtime.save_lock))return 6;runtime.save_lock=-1;}
  competing_lock=hc_save_directory_lock(parent,geteuid());if(competing_lock>=0){close(competing_lock);fputs("frontend did not retain the save lock\n",stderr);return 6;}if(errno!=EWOULDBLOCK&&errno!=EAGAIN)return 6;
  if(hc_stock_save_signal(&session.save,SIGKILL))return 6;int reaped=0;
  for(int i=0;i<300&&!reaped;i++){int r=hc_stock_save_poll(&session.save,&status);if(r<0)return 6;if(r>0)reaped=1;else nanosleep(&delay,NULL);}
  if(!reaped)return 6;competing_lock=hc_save_directory_lock(parent,geteuid());if(competing_lock<0||close(competing_lock))return 6;
  puts("FRONTEND HELD LOCK UNTIL EXIT");return 0;
 }
 competing_lock=hc_save_directory_lock(parent,geteuid());if(competing_lock>=0){close(competing_lock);fputs("running game lost its save lock\n",stderr);return 6;}if(errno!=EWOULDBLOCK&&errno!=EAGAIN)return 6;
 unsigned char reset_event[16]={0};reset_event[8]=1;reset_event[10]=115;reset_event[12]=1;
 if(getenv("HC_ENTRY_POWER")){
  unsigned char power_event[16]={0};power_event[8]=1;power_event[10]=116;power_event[12]=0;
  if(write(power_pipe[1],power_event,sizeof power_event)!=(ssize_t)sizeof power_event)return 6;
 }else if(getenv("HC_ENTRY_MANAGER_SIGNAL")){
  if(raise(SIGTERM)||!hc_ram_menu_term_requested())return 6;
  fputs("MANAGER SIGNAL RESET DISPATCHED\n",stderr);
 }else if(write(reset_pipe[1],reset_event,sizeof reset_event)!=(ssize_t)sizeof reset_event)return 6;
 int done=0;for(int i=0;i<1200&&!done;i++){
  if(clock_gettime(CLOCK_MONOTONIC,&stamp))return 7;
  uint64_t now=(uint64_t)stamp.tv_sec*1000u+(uint64_t)stamp.tv_nsec/1000000u;
  done=use_gameplay?hc_stock_gameplay_poll(&gameplay,now,&status):hc_stock_control_step(&control,now,&status);if(done<0){if(screenshot_mode)fprintf(stderr,"Screenshot exit failed: phase=%d capturing=%d failed=%d errno=%d\n",shot.phase,control.capturing,control.failed,errno);return 7;}if(!done)nanosleep(&delay,NULL);
 }
 if(done!=1||!WIFEXITED(status)||WEXITSTATUS(status))return 8;
 if(control.reason!=(getenv("HC_ENTRY_POWER")?HC_STOCK_CONTROL_POWER:HC_STOCK_CONTROL_RESET))return 8;
 if(screenshot_mode){if(shot.phase!=3||!shot.image_length||memcmp(shot.token,session.token,16))return 8;puts("SESSION SCREENSHOT VERIFIED");}
 if(getenv("HC_ENTRY_TAMPER_ACTUAL_MANAGER_RECORD_LATE")){
  int fd=openat(runtime.workspace,"manager.meta",O_WRONLY|O_NOFOLLOW|O_CLOEXEC);
  if(fd<0||pwrite(fd,"X",1,0)!=1||close(fd))return 8;
 }
 if(getenv("HC_ENTRY_RETAIN_SCREENSHOT")){
  if(!screenshot_mode)return 8;
  if(!getenv("HC_ENTRY_RETAIN_NO_SRAM")){
   int save_phase=session.save.phase;session.save.phase=HC_STOCK_REAPED_NO_SRAM;
   if(!hc_stock_retained_image_prepare(&retained_image,&session,&control,&shot)||retained_image.attempted)return 8;session.save.phase=save_phase;
  }
  shot.token[0]^=1;if(!hc_stock_retained_image_prepare(&retained_image,&session,&control,&shot)||retained_image.attempted)return 8;shot.token[0]^=1;
  shot.image[0]^=1;if(!hc_stock_retained_image_prepare(&retained_image,&session,&control,&shot)||retained_image.attempted)return 8;shot.image[0]^=1;
  if(getenv("HC_ENTRY_RETAIN_CONFLICT")){
   HCScreenshotSessionNames names;if(hc_screenshot_session_names(session.token,&names))return 8;
   int fd=openat(parent,names.retained_file,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
   if(fd<0||write(fd,"KEEP",4)!=4||close(fd))return 8;
  }
 }
 if(state_mode){
  unsigned char digest[32];HCStateBytes packed=HC_STATE_BYTES_INITIALIZER,unpacked=HC_STATE_BYTES_INITIALIZER;
  if(state.phase!=3||!state.bytes||!state.length||mbedtls_sha256(state.bytes,state.length,digest,0)||
     hc_state_gzip_encode(state.bytes,state.length,&packed)||hc_state_decode(packed.data,packed.length,&unpacked)||
     unpacked.length!=state.length||memcmp(unpacked.data,state.bytes,state.length))return 8;
  int fd=openat(stage,"210.state.gz",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0)return 8;
  int failed=0;for(size_t pos=0;pos<packed.length;){ssize_t n=write(fd,packed.data+pos,packed.length-pos);if(n<0&&errno==EINTR)continue;if(n<=0){failed=1;break;}pos+=(size_t)n;}
  if(!failed&&fsync(fd))failed=1;if(close(fd))failed=1;
  hc_state_bytes_clear(&unpacked);hc_state_bytes_clear(&packed);
  if(failed)return 8;
  fputs("SESSION STATE CAPTURED BEFORE SCREENSHOT ",stdout);
  for(size_t i=0;i<sizeof digest;i++)printf("%02x",digest[i]);
  printf(" %zu\n",state.length);
  if(getenv("HC_ENTRY_RETAIN_STATE")){
   if(getenv("HC_ENTRY_STATE_ARCHIVE_CONFLICT")){
    if(mkdirat(runtime.workspace,"state-archive",0700))return 8;
    int d=openat(runtime.workspace,"state-archive",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(d<0)return 8;
    int fd=openat(d,"KEEP",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(fd<0||write(fd,"keep",4)!=4||close(fd)||close(d))return 8;
   }
   if(getenv("HC_ENTRY_STATE_ARCHIVE_TAMPER")){
    int fd=openat(stage,"210.state",O_WRONLY|O_NOFOLLOW|O_CLOEXEC);if(fd<0||pwrite(fd,"X",1,0)!=1||close(fd))return 8;
   }
  }
 }
 if(getenv("HC_ENTRY_LATE_RESET_LOSS")){if(close(reset_pipe[1]))return 8;reset_pipe[1]=-1;}
 if(getenv("HC_ENTRY_LATE_POWER")&&!getenv("HC_ENTRY_LATE_POWER_AFTER_PUBLISH")){unsigned char e[16]={0};e[8]=1;e[10]=116;if(write(power_pipe[1],e,sizeof e)!=(ssize_t)sizeof e)return 8;}
 if(session.save.phase==HC_STOCK_REAPED_NO_SRAM){
  /* A positive detection must not accept a conflicting no-SRAM report. */
  session.detected_no_sram=0;
  if(hc_stock_game_validate_no_sram(&session)==0){fputs("unexpected no-SRAM result accepted\n",stderr);return 8;}
  session.detected_no_sram=1;
  if(getenv("HC_ENTRY_NO_SRAM_WRONG_ABSENCE")){
   /* Simulate an unexpectedly missing original in a disposable fixture. */
   if(unlinkat(parent,"battery.srm",0))return 9;
   if(!hc_stock_game_finish_no_sram(&session,NULL,0))return 10;
   return 8;
  }
  if(getenv("HC_ENTRY_TAMPER_STAGE")){
   int fd=openat(stage,"210.srm",O_WRONLY|O_TRUNC|O_NOFOLLOW|O_CLOEXEC);if(fd<0||write(fd,"X",1)!=1||close(fd))return 8;
  }
  /* Only this host fixture knows these independent initial bytes. Production
   * must bind its own trusted snapshot and establish exclusive access. */
  if(getenv("HC_ENTRY_WRONG_INITIAL")||getenv("HC_ENTRY_RETRY_SNAPSHOT")){
   if(!session.save.initial_bytes||!session.save.initial_length)return 8;
   session.save.initial_bytes[0]^=1;
   if(getenv("HC_ENTRY_RETRY_SNAPSHOT")){
    if(hc_stock_game_finish_no_sram_captured(&session)==0||!session.save.initial_bytes)return 8;
    session.save.initial_bytes[0]^=1;
   }
  }
  if(getenv("HC_ENTRY_RETRY_PARTIAL")){
   if(hc_stock_game_finish_no_sram_captured(&session)!=-2||!session.save.initial_bytes)return 8;
  }
  if(getenv("HC_ENTRY_CLEAN_FINISHED")&&hc_stock_game_discard_finished_runtime(&session,&runtime,sessionfd,&supervisor,game,&control)==0)return 10;
  HCStockControlReason saved_reason=control.reason;control.reason=HC_STOCK_CONTROL_NONE;
  if(!hc_stock_game_finish_no_sram_after_exit(&session,&control)){fputs("Missing exit reason incorrectly permitted no-SRAM cleanup\n",stderr);return 10;}control.reason=saved_reason;
  int finished;
  if(getenv("HC_ENTRY_SHARED_NO_SRAM")&&getenv("HC_ENTRY_CAPTURE_PRIOR")){
   if(use_gameplay){finished=getenv("HC_ENTRY_RESUMED_TIME")?test_resume_finish(&gameplay,&resume):getenv("HC_ENTRY_ORDERED_MANAGER_IMAGE")?test_ordered_manager_image_finish(&gameplay,game,&runtime,&session,stage,argc,argv):hc_stock_gameplay_finish(&gameplay);if(!finished)puts("GAMEPLAY OWNER COMPLETED");}
   else {finished=hc_stock_previous_finish(&captured_previous,&session,&control);if(!finished)hc_stock_previous_clear(&captured_previous);}
   if(!finished){puts("CAPTURED PRIOR SAVE USED");puts("SHARED NO-SRAM FINALIZATION VERIFIED");}
  }else if(getenv("HC_ENTRY_SHARED_NO_SRAM")){
   unsigned char previous[131072];if(save_size>sizeof previous)return 8;
   for(size_t i=0;i<save_size;i++)previous[i]=(unsigned char)(i*13+97);
   previous[0]^=1;
   if(hc_stock_entry_finish_no_sram(&session,&control,previous,save_size)!=-1||session.save.phase!=HC_STOCK_REAPED_NO_SRAM)return 8;
   previous[0]^=1;
   finished=hc_stock_entry_finish_no_sram(&session,&control,session.save.initial_present?previous:NULL,session.save.initial_present?save_size:0);
   if(!finished)puts("SHARED NO-SRAM FINALIZATION VERIFIED");
  }else finished=getenv("HC_ENTRY_ALIAS_SNAPSHOT")?hc_stock_game_finish_no_sram(&session,session.save.initial_bytes,session.save.initial_length):hc_stock_game_finish_no_sram_after_exit(&session,&control);
  if(finished)return 8;
  if(getenv("HC_ENTRY_RETAIN_NO_SRAM")){
   if(getenv("HC_ENTRY_TEST_MANAGER_IMAGE")&&!getenv("HC_ENTRY_ORDERED_MANAGER_IMAGE")&&test_manager_image_publication(game,&runtime,&session,&control,&shot,&retained_image,stage,argc,argv))return 8;
   if(!retained_image.published||hc_stock_retained_image_close(&retained_image))return 8;
   hc_stock_screenshot_receipt_clear(&shot);if(close(receipt_read)||close(shot_dir))return 8;
   puts("SESSION SCREENSHOT RETAINED");
  }
  if(getenv("HC_ENTRY_CLEAN_FINISHED")){
   control.failed=1;if(hc_stock_game_discard_finished_runtime(&session,&runtime,sessionfd,&supervisor,game,&control)==0)return 10;control.failed=0;
   control.exit_owner.timed_out=1;if(hc_stock_game_discard_finished_runtime(&session,&runtime,sessionfd,&supervisor,game,&control)==0)return 10;control.exit_owner.timed_out=0;
   saved_reason=control.reason;control.reason=HC_STOCK_CONTROL_NONE;
   if(!hc_stock_game_discard_finished_runtime(&session,&runtime,sessionfd,&supervisor,game,&control)){fputs("Missing exit reason incorrectly permitted session cleanup\n",stderr);return 10;}control.reason=saved_reason;
   if(hc_stock_game_discard_finished_runtime(&session,&runtime,sessionfd,&supervisor,game,&control))return 9;
  }
  if(getenv("HC_ENTRY_RUNTIME_LOCK")&&runtime.save_lock<0&&session.save_lock>=0){
   int still_locked=hc_save_directory_lock(parent,geteuid());if(still_locked>=0){close(still_locked);return 9;}
   puts("SESSION LOCK SURVIVED RUNTIME CLOSE");
  }
  if(selected_state.ready&&hc_stock_selected_state_close(&selected_state))return 8;
  if(selected_parent>=0&&close(selected_parent))return 8;if(prior_profiles>=0&&close(prior_profiles))return 8;
  if(native_state.attempted&&hc_stock_manager_state_close(&native_state))return 8;
  if(native_state_parent>=0&&close(native_state_parent))return 8;
  if(getenv("HC_ENTRY_RETAIN_STATE")&&hc_stock_state_archive_close(&archive))return 8;
  hc_state_bytes_clear(&state_package);
  if(hc_stock_game_close(&session))return 8;
  if(getenv("HC_ENTRY_RUNTIME_LOCK")&&runtime.save_lock>=0){
   int still_locked=hc_save_directory_lock(parent,geteuid());if(still_locked>=0){close(still_locked);return 9;}
   if(hc_console_runtime_close(&runtime,&supervisor))return 9;
  }
  int after_lock=hc_save_directory_lock(parent,geteuid());if(after_lock<0||close(after_lock))return 8;
  if((manager_signal?close(reset_pipe[0]):hc_stock_reset_close_named(&reset))||close(reset_pipe[1]))return 8;
  if(power_pipe[0]>=0&&(hc_stock_power_close_named(&power)||close(power_pipe[1])))return 8;
  if(hc_verified_launch_close(&frontend)||hc_verified_launch_close(&core)||hc_verified_launch_close(&config)||(runtime.workspace>=0&&hc_console_runtime_close(&runtime,&supervisor))||close(sessionfd)||close(rootfd)||close(parent)||close(stage))return 9;
  puts("ENTRY NO SRAM CLEAN");return 0;
 }
 if(getenv("HC_ENTRY_CREATE_TARGET")){
  int fd=openat(parent,"battery.srm",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0||write(fd,"new",3)!=3||close(fd))return 9;
 }
 if(getenv("HC_ENTRY_CHANGE_TARGET")){
  /* Simulate an outside change in this disposable host fixture. */
  int fd=openat(parent,"battery.srm",O_WRONLY|O_NOFOLLOW|O_CLOEXEC);if(fd<0||pwrite(fd,"X",1,0)!=1||close(fd))return 9;
 }
 /* Simulate a no-SRAM detection followed by an unexpected save report. */
 session.detected_no_sram=1;
 if(hc_stock_game_publish_stage(&session)==0){fputs("unexpected save was published\n",stderr);return 8;}
 session.detected_no_sram=0;
 control.failed=1;if(!hc_stock_game_publish_after_exit(&session,&control))return 8;control.failed=0;
 control.exit_owner.timed_out=1;if(!hc_stock_game_publish_after_exit(&session,&control))return 8;control.exit_owner.timed_out=0;
 control.exit_owner.kill_sent=1;if(!hc_stock_game_publish_after_exit(&session,&control))return 8;control.exit_owner.kill_sent=0;
 control.save=NULL;if(!hc_stock_game_publish_after_exit(&session,&control))return 8;control.save=&session.save;
 control.exit_owner.save=NULL;if(!hc_stock_game_publish_after_exit(&session,&control))return 8;control.exit_owner.save=&session.save;
 control.started=0;if(!hc_stock_game_publish_after_exit(&session,&control))return 8;control.started=1;
 control.finished=0;if(!hc_stock_game_publish_after_exit(&session,&control))return 8;control.finished=1;
 control.exit_owner.phase=1;if(!hc_stock_game_publish_after_exit(&session,&control))return 8;control.exit_owner.phase=2;
 HCStockControlReason saved_reason=control.reason;control.reason=HC_STOCK_CONTROL_NONE;
 if(!hc_stock_game_publish_after_exit(&session,&control)){fputs("Missing exit reason incorrectly permitted publication\n",stderr);return 8;}control.reason=saved_reason;
 if(getenv("HC_ENTRY_SHARED_FINALIZE")){
  if(getenv("HC_ENTRY_CAPTURE_PRIOR")){
   if(use_gameplay){if(getenv("HC_ENTRY_RESUMED_TIME")?test_resume_finish(&gameplay,&resume):getenv("HC_ENTRY_ORDERED_MANAGER_IMAGE")?test_ordered_manager_image_finish(&gameplay,game,&runtime,&session,stage,argc,argv):hc_stock_gameplay_finish(&gameplay))return 8;puts("GAMEPLAY OWNER COMPLETED");}
   else {if(hc_stock_previous_finish(&captured_previous,&session,&control))return 8;hc_stock_previous_clear(&captured_previous);}
   puts("CAPTURED PRIOR SAVE USED");puts("SHARED SAVE FINALIZATION VERIFIED");
   if(getenv("HC_ENTRY_RETAIN_SCREENSHOT")){if(!retained_image.published)return 8;puts("SESSION SCREENSHOT RETAINED");}
   goto shared_finish_done;
  }
  unsigned char previous[131072];if(save_size>sizeof previous)return 8;
  for(size_t i=0;i<save_size;i++)previous[i]=(unsigned char)(i*13+97);
  if(getenv("HC_ENTRY_PREVIOUS_FIRST_INCREMENTED"))previous[0]++;
  previous[0]^=1;
  if(hc_stock_entry_publish_and_finish(&session,&control,previous,save_size)!=-1||session.save.phase!=HC_STOCK_REAPED_CLEAN)return 8;
  previous[0]^=1;
  const void *reviewed_previous=session.save.initial_present?previous:NULL;
  size_t reviewed_length=session.save.initial_present?save_size:0;
  if(hc_stock_entry_publish_and_finish(&session,&control,reviewed_previous,reviewed_length))return 8;
  puts("SHARED SAVE FINALIZATION VERIFIED");
  goto shared_finish_done;
 }
 if(hc_stock_game_publish_after_exit(&session,&control))return 8;
 if(getenv("HC_ENTRY_LATE_POWER")&&!getenv("HC_ENTRY_LATE_POWER_AFTER_PUBLISH")){if(control.reason!=HC_STOCK_CONTROL_POWER)return 8;puts("LATE POWER OBSERVED");}
 if(getenv("HC_ENTRY_LATE_POWER_AFTER_PUBLISH")){unsigned char e[16]={0};e[8]=1;e[10]=116;if(write(power_pipe[1],e,sizeof e)!=(ssize_t)sizeof e)return 8;}
 if(getenv("HC_ENTRY_LATE_RESET_LOSS")){fputs("LATE INPUT LOSS ACCEPTED\n",stderr);return 10;}
 if(getenv("HC_ENTRY_LATE_CLEANUP_LOSS")){if(close(reset_pipe[1]))return 8;reset_pipe[1]=-1;}
 if(getenv("HC_ENTRY_CLEAN_FINISHED")&&hc_stock_game_discard_finished_runtime(&session,&runtime,sessionfd,&supervisor,game,&control)==0)return 10;
 if(getenv("HC_ENTRY_FINISH_SAVE")){
  unsigned char current[131072],previous[131072];for(size_t i=0;i<save_size;i++)current[i]=previous[i]=(unsigned char)(i*13+97);
  /* Independent expectation for the second run of the homebrew save test. */
  if(getenv("HC_ENTRY_PREVIOUS_FIRST_INCREMENTED"))previous[0]++;
  if(getenv("HC_ENTRY_WRONG_CURRENT"))current[0]^=1;
  if(getenv("HC_ENTRY_WRONG_PREVIOUS"))previous[0]^=1;
  if(getenv("HC_ENTRY_WRONG_ABSENCE")){
   /* Simulate a partial cleanup in this disposable test workspace only. */
   if(unlinkat(session.save.target.workspace,"previous",0))return 9;
   if(!hc_stock_game_finish_published(&session,current,save_size,NULL,0))return 10;
   return 8;
  }
  if(getenv("HC_ENTRY_FIRST_SAVE")){
   /* Host fixture only: copy the completed stage as expected bytes. A real
    * supervisor must independently authenticate this outcome and absence. */
   if(!session.save.initial_valid||session.save.initial_present)return 8;
   if(getenv("HC_ENTRY_CAPTURED_FINISH")){
    if(hc_stock_game_finish_published_after_exit(&session,&control,NULL,0))return 8;
   }else{
    int fd=openat(stage,"210.srm",O_RDONLY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return 8;
    size_t used=0;while(used<save_size){ssize_t n=read(fd,current+used,save_size-used);if(n<=0){close(fd);return 8;}used+=(size_t)n;}
    if(close(fd)||hc_stock_game_finish_published(&session,current,save_size,NULL,0))return 8;
   }
  }else if(getenv("HC_ENTRY_CAPTURED_FINISH")){
   /* Host-only negative checks retain the published save and its journal. */
   if(!session.save.published_bytes||session.save.published_length!=save_size)return 8;
   previous[0]^=1;
   if(!hc_stock_game_finish_published_captured(&session,previous,save_size))return 8;
   previous[0]^=1;session.save.published_bytes[0]^=1;
   if(!hc_stock_game_finish_published_captured(&session,previous,save_size))return 8;
   session.save.published_bytes[0]^=1;
   int changed=openat(parent,"battery.srm",O_RDWR|O_NOFOLLOW|O_CLOEXEC);if(changed<0)return 8;
   unsigned char altered=session.save.published_bytes[0]^1;
   if(pwrite(changed,&altered,1,0)!=1||!hc_stock_game_finish_published_captured(&session,previous,save_size)||
      pwrite(changed,session.save.published_bytes,1,0)!=1||close(changed))return 8;
   if(hc_stock_game_finish_published_after_exit(&session,&control,previous,save_size))return 8;
   if(getenv("HC_ENTRY_LATE_POWER_AFTER_PUBLISH")){if(control.reason!=HC_STOCK_CONTROL_POWER)return 8;puts("POWER AFTER PUBLICATION OBSERVED");}
   if(getenv("HC_ENTRY_LATE_CLEANUP_LOSS")){fputs("LATE CLEANUP LOSS ACCEPTED\n",stderr);return 10;}
  }else if(hc_stock_game_finish_published(&session,current,save_size,previous,save_size))return 8;
 }
 shared_finish_done:
 if(getenv("HC_ENTRY_TEST_MANAGER_IMAGE")&&!getenv("HC_ENTRY_ORDERED_MANAGER_IMAGE")&&test_manager_image_publication(game,&runtime,&session,&control,&shot,&retained_image,stage,argc,argv))return 9;
 if(getenv("HC_ENTRY_CLEAN_FINISHED")){
  game->command.checkpoint.have_image=1;
  if(hc_stock_game_discard_finished_runtime(&session,&runtime,sessionfd,&supervisor,game,&control)==0)return 10;
  game->command.checkpoint.have_image=0;runtime.request.session[0]^=1;
  if(hc_stock_game_discard_finished_runtime(&session,&runtime,sessionfd,&supervisor,game,&control)==0)return 10;
  runtime.request.session[0]^=1;
  control.failed=1;if(hc_stock_game_discard_finished_runtime(&session,&runtime,sessionfd,&supervisor,game,&control)==0)return 10;control.failed=0;
  control.exit_owner.timed_out=1;if(hc_stock_game_discard_finished_runtime(&session,&runtime,sessionfd,&supervisor,game,&control)==0)return 10;control.exit_owner.timed_out=0;
  control.exit_owner.kill_sent=1;if(hc_stock_game_discard_finished_runtime(&session,&runtime,sessionfd,&supervisor,game,&control)==0)return 10;control.exit_owner.kill_sent=0;
  /* A changed session record must be retained, not silently cleaned up. */
  int meta=openat(runtime.workspace,"manager.meta",O_RDWR|O_NOFOLLOW|O_CLOEXEC);unsigned char marker;
  if(meta<0||pread(meta,&marker,1,0)!=1||pwrite(meta,"X",1,0)!=1)return 9;
  if(!hc_stock_game_discard_finished_runtime(&session,&runtime,sessionfd,&supervisor,game,&control))return 10;
  if(pwrite(meta,&marker,1,0)!=1||close(meta))return 9;
  if(hc_stock_game_discard_finished_runtime(&session,&runtime,sessionfd,&supervisor,game,&control))return 9;
 }
 if((manager_signal?close(reset_pipe[0]):hc_stock_reset_close_named(&reset))||close(reset_pipe[1]))return 8;
 if(power_pipe[0]>=0&&(hc_stock_power_close_named(&power)||close(power_pipe[1])))return 8;
 if(getenv("HC_ENTRY_RUNTIME_LOCK")&&runtime.save_lock<0&&session.save_lock>=0){
  int still_locked=hc_save_directory_lock(parent,geteuid());if(still_locked>=0){close(still_locked);return 9;}
  puts("SESSION LOCK SURVIVED RUNTIME CLOSE");
 }
 if(selected_state.ready&&hc_stock_selected_state_close(&selected_state))return 9;
 if(selected_parent>=0&&close(selected_parent))return 9;if(prior_profiles>=0&&close(prior_profiles))return 9;
 if(native_state.attempted&&hc_stock_manager_state_close(&native_state))return 9;
 if(native_state_parent>=0&&close(native_state_parent))return 9;
 if(getenv("HC_ENTRY_RETAIN_STATE")&&hc_stock_state_archive_close(&archive))return 9;
 hc_state_bytes_clear(&state_package);
 if(state_mode)hc_stock_state_receipt_clear(&state);
 if(getenv("HC_ENTRY_RETAIN_SCREENSHOT")&&hc_stock_retained_image_close(&retained_image))return 9;
 if(screenshot_mode){hc_stock_screenshot_receipt_clear(&shot);if(close(receipt_read)||close(shot_dir))return 9;}
 if(hc_stock_game_close(&session))return 9;
 if(getenv("HC_ENTRY_TEST_REPLAY")){
  HCStockGameSession replay=HC_STOCK_GAME_SESSION_INITIALIZER;
  if(!hc_stock_game_prepare_runtime(&replay,&runtime,game,argc,argv,profiles,parent,stage,"210.srm",save_size)){
   (void)hc_stock_game_close(&replay);fputs("REPLAYED SESSION ACCEPTED\n",stderr);return 11;
  }
  if(replay.save_lock!=-1||replay.rom.ready||replay.save.phase!=HC_STOCK_EMPTY){fputs("REPLAY TOUCHED SAVE SESSION\n",stderr);(void)hc_stock_game_close(&replay);return 11;}
  if(hc_stock_game_close(&replay))return 11;
  fputs("REPLAYED SESSION REFUSED\n",stderr);
 }
 if(getenv("HC_ENTRY_RUNTIME_LOCK")&&runtime.save_lock>=0){
  int still_locked=hc_save_directory_lock(parent,geteuid());if(still_locked>=0){close(still_locked);return 9;}
  if(hc_console_runtime_close(&runtime,&supervisor))return 9;
 }
 int after_lock=hc_save_directory_lock(parent,geteuid());if(after_lock<0||close(after_lock))return 9;
 if(hc_verified_launch_close(&frontend)||hc_verified_launch_close(&core)||hc_verified_launch_close(&config)||(runtime.workspace>=0&&hc_console_runtime_close(&runtime,&supervisor))||close(sessionfd)||close(rootfd)||close(parent)||close(stage))return 9;
 puts("ENTRY REAL FRONTEND SAVE VERIFIED");return 0;
}
