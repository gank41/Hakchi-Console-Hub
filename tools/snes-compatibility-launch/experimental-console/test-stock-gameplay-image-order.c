#include "stock-gameplay.h"
#include "stock-manager-image.h"
#include <assert.h>
#include <string.h>
int hc_console_game_check_manager_record_full(int fd,const HCLaunchRequest *r,const HCManagerCheckpointPaths *c,const HCManagerTimePaths *t){(void)fd;(void)r;(void)c;(void)t;return 0;}
int hc_stock_state_archive_capture(HCStockStateArchive *a,HCStockStateReceipt *s,HCStockGameSession *g,HCConsoleRuntime *r,HCStockControlSession *c){(void)a;(void)s;(void)g;(void)r;(void)c;return -1;}
int hc_stock_state_archive_recheck(HCStockStateArchive *a,HCStockStateReceipt *s,HCStockGameSession *g,HCConsoleRuntime *r,HCStockControlSession *c){(void)a;(void)s;(void)g;(void)r;(void)c;return -1;}
int hc_stock_state_archive_encode(HCStockStateArchive *a,HCStockStateReceipt *s,HCStockGameSession *g,HCConsoleRuntime *r,HCStockControlSession *c,HCStateBytes *b){(void)a;(void)s;(void)g;(void)r;(void)c;(void)b;return -1;}
int hc_stock_manager_state_preflight(HCStockManagerState *o,HCStockGameSession *g,HCConsoleRuntime *r,HCConsoleGame *m,int p){(void)o;(void)g;(void)r;(void)m;(void)p;return -1;}
int hc_stock_manager_state_publish(HCStockManagerState *o,HCStockGameSession *g,HCConsoleRuntime *r,HCConsoleGame *m,HCStockControlSession *c,HCStockStateReceipt *s,HCStockStateArchive *a,const HCStateBytes *b,int p){(void)o;(void)g;(void)r;(void)m;(void)c;(void)s;(void)a;(void)b;(void)p;return -1;}
int hc_stock_manager_state_recheck(HCStockManagerState *o,HCStockGameSession *g,HCConsoleRuntime *r,HCConsoleGame *m,HCStockControlSession *c,HCStockStateReceipt *s,HCStockStateArchive *a,const HCStateBytes *b,int p){(void)o;(void)g;(void)r;(void)m;(void)c;(void)s;(void)a;(void)b;(void)p;return -1;}
int hc_stock_selected_state_recheck(HCStockSelectedState *s){(void)s;return -1;}
int hc_stock_retained_image_retire(HCStockRetainedImage *i,HCStockGameSession *s,HCStockControlSession *c,HCStockScreenshotReceipt *p){(void)i;(void)s;(void)c;(void)p;return 0;}

static char order[16];
static size_t used;
static int image_result,time_result;
static void mark(char c){order[used++]=c;order[used]=0;}
int hc_stock_previous_validate(HCStockPrevious *p,HCStockGameSession *s){(void)p;(void)s;return 0;}
void hc_stock_previous_clear(HCStockPrevious *p){memset(p,0,sizeof *p);}
int hc_stock_previous_finish(HCStockPrevious *p,HCStockGameSession *s,HCStockControlSession *c){(void)p;(void)s;(void)c;mark('P');return 0;}
int hc_stock_retained_image_prepare(HCStockRetainedImage *i,HCStockGameSession *s,HCStockControlSession *c,HCStockScreenshotReceipt *r){(void)s;(void)c;(void)r;mark('R');i->attempted=1;return 0;}
int hc_stock_game_publish_after_exit(HCStockGameSession *s,HCStockControlSession *c){(void)c;mark('S');s->save.phase=HC_STOCK_PUBLISHED;return 0;}
int hc_stock_retained_image_finish_save(HCStockRetainedImage *i,HCStockGameSession *s,HCStockControlSession *c,HCStockScreenshotReceipt *r,const void *b,size_t n){(void)i;(void)s;(void)c;(void)r;(void)b;(void)n;mark('V');return 0;}
int hc_stock_retained_image_finish_no_sram(HCStockRetainedImage *i,HCStockGameSession *s,HCStockControlSession *c,HCStockScreenshotReceipt *r,const void *b,size_t n){(void)i;(void)s;(void)c;(void)r;(void)b;(void)n;mark('N');return 0;}
int hc_stock_manager_image_publish(HCStockManagerImage *i,HCStockRetainedImage *retained,HCStockGameSession *s,HCStockControlSession *c,HCStockScreenshotReceipt *shot,HCConsoleRuntime *runtime,HCConsoleGame *menu,int parent){
 assert(i&&retained&&s&&c&&shot&&runtime&&menu&&parent==17);mark('I');i->attempted=1;return image_result;
}
int hc_stock_manager_time_publish(HCStockManagerTime *time,HCStockManagerImage *image,HCStockRetainedImage *retained,HCStockGameSession *s,HCStockControlSession *c,HCStockScreenshotReceipt *shot,HCConsoleRuntime *runtime,HCConsoleGame *menu,int parent,HCPlaytimeInstant start,HCPlaytimeInstant end){
 assert(time&&image&&retained&&s&&c&&shot&&runtime&&menu&&parent==17&&start.seconds==10&&end.seconds==53);mark('T');time->attempted=1;return time_result;
}
int hc_stock_time_seed_recheck(HCStockTimeSeed *seed,HCStockGameSession *s,HCConsoleRuntime *r,HCConsoleGame *g,int parent){(void)s;(void)r;(void)g;(void)parent;return seed&&seed->ready?0:-1;}
int hc_stock_time_seed_retain(HCStockTimeSeed *seed,HCStockGameSession *s,HCConsoleRuntime *r){(void)s;(void)r;return seed&&seed->ready?0:-1;}
int hc_stock_time_seed_backup_recheck(HCStockTimeSeed *seed,HCStockGameSession *s,HCConsoleRuntime *r){(void)s;(void)r;return seed&&seed->ready?0:-1;}
int hc_stock_manager_time_publish_resumed(HCStockManagerTime *time,HCStockManagerImage *image,HCStockRetainedImage *retained,HCStockGameSession *s,HCStockControlSession *c,HCStockScreenshotReceipt *shot,HCConsoleRuntime *runtime,HCConsoleGame *menu,HCStockTimeSeed *seed,int parent,HCPlaytimeInstant start,HCPlaytimeInstant end){
 assert(seed&&seed->ready);return hc_stock_manager_time_publish(time,image,retained,s,c,shot,runtime,menu,parent,start,end);
}
int hc_transition_finish_exit(HCTransition *t){assert(t&&t->phase==HC_EXITING);mark('F');t->phase=HC_COMPLETE;return 0;}

static void setup(HCStockGameplay *g,HCStockEntryLaunch *entry,HCStockGameSession *session,HCStockControlSession *control,HCStockRetainedImage *retained,HCStockScreenshotReceipt *shot,HCTransition *transition,HCConsoleRuntime *runtime,HCConsoleGame *menu,HCStockManagerImage *image,int no_sram){
 *g=(HCStockGameplay)HC_STOCK_GAMEPLAY_INITIALIZER;*entry=(HCStockEntryLaunch)HC_STOCK_ENTRY_LAUNCH_INITIALIZER;
 *session=(HCStockGameSession)HC_STOCK_GAME_SESSION_INITIALIZER;*control=(HCStockControlSession)HC_STOCK_CONTROL_SESSION_INITIALIZER;
 *retained=(HCStockRetainedImage)HC_STOCK_RETAINED_IMAGE_INITIALIZER;*shot=(HCStockScreenshotReceipt)HC_STOCK_SCREENSHOT_RECEIPT_INITIALIZER;
 *transition=(HCTransition){11,13,14,HC_EXITING};*runtime=(HCConsoleRuntime)HC_CONSOLE_RUNTIME_INITIALIZER;*menu=(HCConsoleGame)HC_CONSOLE_GAME_INITIALIZER;
 *image=(HCStockManagerImage)HC_STOCK_MANAGER_IMAGE_INITIALIZER;entry->session=session;entry->control=control;entry->runtime=runtime;entry->game=menu;
 menu->command.checkpoint.have_image=1;menu->command.manager.present=1u<<HC_SCREENSHOT;
 control->transition=transition;g->entry=entry;g->session=session;g->control=control;g->phase=HC_GAMEPLAY_STOPPED;g->transition=transition;
 g->retained_image=retained;g->image_capture=shot;session->save.phase=no_sram?HC_STOCK_REAPED_NO_SRAM:HC_STOCK_REAPED_CLEAN;
 g->clock_enabled=1;g->clock_started=1;g->clock_stopped=1;g->clock_start=(HCPlaytimeInstant){10,200000000};g->clock_end=(HCPlaytimeInstant){53,500000000};
 used=0;order[0]=0;image_result=0;time_result=0;
}
int main(void){
 HCStockGameplay g;HCStockEntryLaunch entry;HCStockGameSession session;HCStockControlSession control;HCStockRetainedImage retained;
 HCStockScreenshotReceipt shot;HCTransition transition;HCConsoleRuntime runtime;HCConsoleGame menu;HCStockManagerImage image;
 setup(&g,&entry,&session,&control,&retained,&shot,&transition,&runtime,&menu,&image,0);
 assert(!hc_stock_gameplay_finish_with_image(&g,&image,17));assert(!strcmp(order,"RSVIF")&&g.phase==HC_GAMEPLAY_FINISHED);
 setup(&g,&entry,&session,&control,&retained,&shot,&transition,&runtime,&menu,&image,1);
 assert(!hc_stock_gameplay_finish_with_image(&g,&image,17));assert(!strcmp(order,"RNIF")&&g.phase==HC_GAMEPLAY_FINISHED);
 setup(&g,&entry,&session,&control,&retained,&shot,&transition,&runtime,&menu,&image,0);image_result=-2;
 assert(hc_stock_gameplay_finish_with_image(&g,&image,17)==-2);assert(!strcmp(order,"RSVI")&&g.phase==HC_GAMEPLAY_RECOVERY&&transition.phase==HC_EXITING);
 assert(hc_stock_gameplay_finish_with_image(&g,&image,17)<0&&!strcmp(order,"RSVI"));
 setup(&g,&entry,&session,&control,&retained,&shot,&transition,&runtime,&menu,&image,0);image_result=-1;
 assert(hc_stock_gameplay_finish_with_image(&g,&image,17)==-2);assert(!strcmp(order,"RSVI")&&g.phase==HC_GAMEPLAY_RECOVERY&&transition.phase==HC_EXITING);
 setup(&g,&entry,&session,&control,&retained,&shot,&transition,&runtime,&menu,&image,0);
 assert(hc_stock_gameplay_finish_with_image(&g,&image,-1)<0&&!used&&g.phase==HC_GAMEPLAY_STOPPED);
 setup(&g,&entry,&session,&control,&retained,&shot,&transition,&runtime,&menu,&image,0);
 menu.command.manager.present|=1u<<HC_SAVE_TIME;
 assert(hc_stock_gameplay_finish_with_image(&g,&image,17)<0&&!used&&g.phase==HC_GAMEPLAY_STOPPED);
 menu.command.manager.present&=~(1u<<HC_SAVE_TIME);menu.command.checkpoint.have_save=1;
 assert(hc_stock_gameplay_finish_with_image(&g,&image,17)<0&&!used&&g.phase==HC_GAMEPLAY_STOPPED);
 setup(&g,&entry,&session,&control,&retained,&shot,&transition,&runtime,&menu,&image,0);
 assert(hc_stock_gameplay_finish(&g)<0&&!used&&g.phase==HC_GAMEPLAY_STOPPED);
 HCStockManagerTime timer=HC_STOCK_MANAGER_TIME_INITIALIZER;
 setup(&g,&entry,&session,&control,&retained,&shot,&transition,&runtime,&menu,&image,0);
 menu.command.manager.present|=1u<<HC_SAVE_TIME;menu.command.time.have_save=1;
 assert(!hc_stock_gameplay_finish_with_image_time(&g,&image,&timer,17));assert(!strcmp(order,"RSVITF")&&g.phase==HC_GAMEPLAY_FINISHED);
 setup(&g,&entry,&session,&control,&retained,&shot,&transition,&runtime,&menu,&image,0);timer=(HCStockManagerTime)HC_STOCK_MANAGER_TIME_INITIALIZER;
 menu.command.manager.present|=1u<<HC_SAVE_TIME;menu.command.time.have_save=1;time_result=-2;
 assert(hc_stock_gameplay_finish_with_image_time(&g,&image,&timer,17)==-2);assert(!strcmp(order,"RSVIT")&&g.phase==HC_GAMEPLAY_RECOVERY&&transition.phase==HC_EXITING);
 setup(&g,&entry,&session,&control,&retained,&shot,&transition,&runtime,&menu,&image,0);timer=(HCStockManagerTime)HC_STOCK_MANAGER_TIME_INITIALIZER;
 menu.command.manager.present|=1u<<HC_SAVE_TIME;menu.command.time.have_save=1;
 g.clock_end.seconds=9;assert(hc_stock_gameplay_finish_with_image_time(&g,&image,&timer,17)<0&&!used&&g.phase==HC_GAMEPLAY_STOPPED);
 g.clock_end.seconds=53;g.clock_stopped=0;assert(hc_stock_gameplay_finish_with_image_time(&g,&image,&timer,17)<0&&!used&&g.phase==HC_GAMEPLAY_STOPPED);
 HCStockTimeSeed seed=HC_STOCK_TIME_SEED_INITIALIZER;seed.ready=1;
 setup(&g,&entry,&session,&control,&retained,&shot,&transition,&runtime,&menu,&image,0);timer=(HCStockManagerTime)HC_STOCK_MANAGER_TIME_INITIALIZER;
 menu.command.manager.present|=(1u<<HC_SAVE_TIME)|(1u<<HC_LOAD_TIME);menu.command.time.have_save=1;menu.command.time.have_load=1;
 assert(hc_stock_gameplay_finish_with_resumed_time(&g,&image,&timer,&seed,17)<0&&!used);
 g.time_seed=&seed;
 assert(!hc_stock_gameplay_finish_with_resumed_time(&g,&image,&timer,&seed,17));assert(!strcmp(order,"RSVITF")&&g.phase==HC_GAMEPLAY_FINISHED);
 setup(&g,&entry,&session,&control,&retained,&shot,&transition,&runtime,&menu,&image,0);timer=(HCStockManagerTime)HC_STOCK_MANAGER_TIME_INITIALIZER;seed.ready=0;
 menu.command.manager.present|=(1u<<HC_SAVE_TIME)|(1u<<HC_LOAD_TIME);menu.command.time.have_save=1;menu.command.time.have_load=1;
 g.time_seed=&seed;
 assert(hc_stock_gameplay_finish_with_resumed_time(&g,&image,&timer,&seed,17)<0&&!used&&g.phase==HC_GAMEPLAY_STOPPED);
 setup(&g,&entry,&session,&control,&retained,&shot,&transition,&runtime,&menu,&image,0);timer=(HCStockManagerTime)HC_STOCK_MANAGER_TIME_INITIALIZER;seed.ready=1;seed.prior=UINT64_MAX;
 menu.command.manager.present|=(1u<<HC_SAVE_TIME)|(1u<<HC_LOAD_TIME);menu.command.time.have_save=1;menu.command.time.have_load=1;g.time_seed=&seed;
 assert(hc_stock_gameplay_finish_with_resumed_time(&g,&image,&timer,&seed,17)<0&&!used&&g.phase==HC_GAMEPLAY_STOPPED);
 return 0;
}
