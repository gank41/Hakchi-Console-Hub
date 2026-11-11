#include "stock-gameplay.h"
#include "test-gameplay-retained-stubs.h"
int hc_stock_game_autoload_ready(HCStockGameSession *s,int a){(void)s;(void)a;return 0;}
int hc_transition_init(HCTransition *t,int w,int a,int f){(void)t;(void)w;(void)a;(void)f;return -1;}
int hc_transition_before_first_frame(HCTransition *t){(void)t;return -1;}
int hc_transition_finish_exit(HCTransition *t){(void)t;return -1;}
int hc_stock_control_attach_transition(HCStockControlSession *c,HCTransition *t){(void)c;(void)t;return -1;}

#include <assert.h>
#include <errno.h>
#include <string.h>
int hc_verified_launch_recheck(HCVerifiedLaunch *v){(void)v;return 0;}
static int capture_result,launch_result,poll_result,finish_result,abort_result,captures,launches,finishes;
int hc_stock_previous_capture(HCStockPrevious *p,HCStockGameSession *s){captures++;if(capture_result)return -1;p->owner=s;p->ready=1;return 0;}
void hc_stock_previous_clear(HCStockPrevious *p){memset(p,0,sizeof *p);}
int hc_stock_previous_finish(HCStockPrevious *p,HCStockGameSession *s,HCStockControlSession *c){(void)c;assert(p->owner==s);finishes++;return finish_result;}
int hc_stock_entry_start(HCStockEntryLaunch *e,HCStockGameSession *s,HCConsoleRuntime *r,HCConsoleGame *g,int t,HCVerifiedLaunch *p,const char *pp,HCVerifiedLaunch *co,const char *cp,HCVerifiedLaunch *cfg,const char *cfp,int a,char *const env[]){(void)e;(void)r;(void)g;(void)t;(void)p;(void)pp;(void)co;(void)cp;(void)cfg;(void)cfp;(void)a;(void)env;launches++;if(launch_result){s->save.child.pid=launch_result==2?-1:123;s->save.child_wait_unknown=launch_result==2;s->save.phase=HC_STOCK_RUNNING;errno=EIO;return -1;}s->save.phase=HC_STOCK_RUNNING;return 0;}
int hc_stock_control_step(HCStockControlSession *c,uint64_t t,int *status){(void)c;(void)t;*status=0;return poll_result;}
int hc_stock_entry_failed_start_poll(HCStockEntryLaunch *e,uint64_t t,int *status){(void)e;(void)t;(void)status;return abort_result;}
static void setup(HCStockEntryLaunch *e,HCStockGameSession *s,HCConsoleRuntime *r,HCConsoleGame *g,HCStockControlSession *c){*e=(HCStockEntryLaunch)HC_STOCK_ENTRY_LAUNCH_INITIALIZER;*s=(HCStockGameSession)HC_STOCK_GAME_SESSION_INITIALIZER;*r=(HCConsoleRuntime)HC_CONSOLE_RUNTIME_INITIALIZER;*g=(HCConsoleGame)HC_CONSOLE_GAME_INITIALIZER;*c=(HCStockControlSession)HC_STOCK_CONTROL_SESSION_INITIALIZER;s->save.phase=HC_STOCK_PREPARED;e->ready=1;e->session=s;e->runtime=r;e->game=g;e->control=c;c->save=&s->save;}
int main(void){HCStockEntryLaunch e;HCStockGameSession s;HCConsoleRuntime r;HCConsoleGame g;HCStockControlSession c;HCStockGameplay x=HC_STOCK_GAMEPLAY_INITIALIZER;HCStockLaunchSpec spec={0};int status;
 setup(&e,&s,&r,&g,&c);assert(!hc_stock_gameplay_prepare(&x,&e)&&captures==1);assert(hc_stock_gameplay_finish(&x)==-1&&finishes==0);assert(!hc_stock_gameplay_start(&x,&spec)&&launches==1);assert(hc_stock_gameplay_start(&x,&spec)==-1&&launches==1);poll_result=0;assert(!hc_stock_gameplay_poll(&x,1,&status));poll_result=1;assert(hc_stock_gameplay_poll(&x,2,&status)==1);finish_result=-2;assert(hc_stock_gameplay_finish(&x)==-2&&x.phase==HC_GAMEPLAY_RECOVERY&&finishes==1);assert(hc_stock_gameplay_finish(&x)==-1&&finishes==1);
 x=(HCStockGameplay)HC_STOCK_GAMEPLAY_INITIALIZER;setup(&e,&s,&r,&g,&c);assert(!hc_stock_gameplay_prepare(&x,&e));launch_result=1;assert(hc_stock_gameplay_start(&x,&spec)==-1&&x.phase==HC_GAMEPLAY_ABORTING);abort_result=0;assert(!hc_stock_gameplay_poll(&x,3,&status));abort_result=1;assert(hc_stock_gameplay_poll(&x,4,&status)==-1&&x.phase==HC_GAMEPLAY_FAILED);assert(hc_stock_gameplay_finish(&x)==-1);
 x=(HCStockGameplay)HC_STOCK_GAMEPLAY_INITIALIZER;setup(&e,&s,&r,&g,&c);assert(!hc_stock_gameplay_prepare(&x,&e));launch_result=2;assert(hc_stock_gameplay_start(&x,&spec)==-1&&x.phase==HC_GAMEPLAY_RECOVERY);
 x=(HCStockGameplay)HC_STOCK_GAMEPLAY_INITIALIZER;setup(&e,&s,&r,&g,&c);s.save.child.pid=123;int before=captures;assert(hc_stock_gameplay_prepare(&x,&e)==-1&&captures==before);
 x=(HCStockGameplay)HC_STOCK_GAMEPLAY_INITIALIZER;setup(&e,&s,&r,&g,&c);g.command.checkpoint.have_save=1;assert(hc_stock_gameplay_prepare(&x,&e)==-1&&captures==before);
 x=(HCStockGameplay)HC_STOCK_GAMEPLAY_INITIALIZER;setup(&e,&s,&r,&g,&c);g.command.checkpoint.have_image=1;assert(hc_stock_gameplay_prepare(&x,&e)==-1&&captures==before);
 const HCLaunchOption unhandled[]={HC_SCREENSHOT,HC_ROLLBACK_OUT,HC_ROLLBACK_MODE,HC_SAVE,HC_ROLLBACK_IN,HC_LOAD,HC_LOAD_TIME,HC_SAVE_TIME};
 for(size_t i=0;i<sizeof unhandled/sizeof unhandled[0];i++){x=(HCStockGameplay)HC_STOCK_GAMEPLAY_INITIALIZER;setup(&e,&s,&r,&g,&c);g.command.manager.present=1u<<unhandled[i];assert(hc_stock_gameplay_prepare(&x,&e)==-1&&captures==before);}
 x=(HCStockGameplay)HC_STOCK_GAMEPLAY_INITIALIZER;setup(&e,&s,&r,&g,&c);x.clock_started=1;
 assert(hc_stock_gameplay_prepare(&x,&e)==-1&&captures==before);
 /* A real menu request must be present before launch, not added at exit.
  * Missing screenshot, timer or manager ownership must prevent child start. */
 x=(HCStockGameplay)HC_STOCK_GAMEPLAY_INITIALIZER;setup(&e,&s,&r,&g,&c);
 r.workspace=17;
 g.command.checkpoint.have_image=1;g.command.time.have_save=1;
 strcpy(g.command.checkpoint.image,"/same/state.png");strcpy(g.command.time.save,"/same/state.time");
 g.command.manager.present=(1u<<HC_SCREENSHOT)|(1u<<HC_SAVE_TIME)|(1u<<HC_WAIT)|(1u<<HC_START)|(1u<<HC_FINISH);
 assert(!hc_stock_gameplay_prepare_manager_outputs(&x,&e));
 int prior_launches=launches;
 assert(hc_stock_gameplay_start(&x,&spec)==-1&&launches==prior_launches&&x.phase==HC_GAMEPLAY_PREPARED);
 HCTransition fake_transition={11,13,14,HC_INITIAL};HCStockScreenshotReceipt shot=HC_STOCK_SCREENSHOT_RECEIPT_INITIALIZER;
 HCStockRetainedImage retained=HC_STOCK_RETAINED_IMAGE_INITIALIZER;HCStockScreenshotCapture capture={0};
 shot.game=&s;shot.phase=1;capture.context=&shot;c.screenshot=&capture;
 x.transition=&fake_transition;x.retained_image=&retained;x.image_capture=&shot;
 assert(hc_stock_gameplay_start(&x,&spec)==-1&&launches==prior_launches); /* no clock */
 x.clock_enabled=1;x.transition=NULL;
 assert(hc_stock_gameplay_start(&x,&spec)==-1&&launches==prior_launches); /* no manager */
 x.transition=&fake_transition;x.retained_image=NULL;
 assert(hc_stock_gameplay_start(&x,&spec)==-1&&launches==prior_launches); /* no retained image */
 x.retained_image=&retained;shot.phase=2;
 assert(hc_stock_gameplay_start(&x,&spec)==-1&&launches==prior_launches); /* stale receipt */
 shot.phase=1;retained.attempted=1;
 assert(hc_stock_gameplay_start(&x,&spec)==-1&&launches==prior_launches); /* consumed target */
 retained.attempted=0;
 g.command.time.save[0]='x';assert(hc_stock_gameplay_start(&x,&spec)==-1&&launches==prior_launches);g.command.time.save[0]='/';
 x=(HCStockGameplay)HC_STOCK_GAMEPLAY_INITIALIZER;setup(&e,&s,&r,&g,&c);
 r.workspace=17;
 g.command.checkpoint.have_image=1;g.command.time.have_save=1;g.command.checkpoint.have_save=1;
 g.command.manager.present=(1u<<HC_SCREENSHOT)|(1u<<HC_SAVE_TIME)|(1u<<HC_WAIT)|(1u<<HC_START)|(1u<<HC_FINISH);
 before=captures;assert(hc_stock_gameplay_prepare_manager_outputs(&x,&e)==-1&&captures==before);
 /* Once the archive exists, even a later prepublication refusal must
  * quarantine the session rather than allow an unsafe retry or cleanup. */
 x=(HCStockGameplay)HC_STOCK_GAMEPLAY_INITIALIZER;setup(&e,&s,&r,&g,&c);
 x.entry=&e;x.session=&s;x.control=&c;x.phase=HC_GAMEPLAY_STOPPED;x.previous.owner=&s;x.previous.ready=1;
 HCStockStateReceipt state=HC_STOCK_STATE_RECEIPT_INITIALIZER;HCStockStateArchive archive=HC_STOCK_STATE_ARCHIVE_INITIALIZER;
 HCStockScreenshotCapture state_control={.context=&state};c.state=&state_control;x.state_capture=&state;x.state_archive=&archive;
 hc_test_archive_result=0;hc_test_previous_validate_result=0;finish_result=-1;
 assert(hc_stock_gameplay_finish(&x)==-1&&archive.attempted&&x.phase==HC_GAMEPLAY_RECOVERY);
 return 0;}
