#include "stock-gameplay.h"
#include "test-gameplay-retained-stubs.h"
#include "transitions.h"
#include <assert.h>
#include <errno.h>
#include <string.h>
static char order[32];static int used,wait_fail,finish_fail,save_fail,invalid_fds,clock_calls,clock_fail;
int hc_stock_game_autoload_ready(HCStockGameSession *s,int a){(void)s;(void)a;return 0;}
static void mark(char c){order[used++]=c;order[used]=0;}
int hc_test_gameplay_clock(HCPlaytimeInstant *out){mark('C');if(++clock_calls==clock_fail)return -1;*out=(HCPlaytimeInstant){clock_calls==1?10:53,200000000};return 0;}
int hc_verified_launch_recheck(HCVerifiedLaunch *v){(void)v;return 0;}
int hc_stock_previous_capture(HCStockPrevious *p,HCStockGameSession *s){p->owner=s;p->ready=1;return 0;}
void hc_stock_previous_clear(HCStockPrevious *p){memset(p,0,sizeof *p);}
int hc_stock_previous_finish(HCStockPrevious *p,HCStockGameSession *s,HCStockControlSession *c){(void)p;(void)s;(void)c;mark('P');return save_fail?-2:0;}
/* Compile the real protocol state machine with only the kernel eventfd I/O
 * replaced. This exercises descriptor validation and ordering together. */
static int hc_test_is_eventfd(int fd){return fd!=invalid_fds&&(fd==11||fd==13||fd==14);}
static int hc_test_wait_counter(int fd,int timeout,uint64_t *value){(void)fd;(void)timeout;mark('W');if(wait_fail)return -1;*value=1;return 0;}
static int hc_test_notify_counter(int fd){(void)fd;mark('F');return finish_fail?-1:0;}
#define HC_TRANSITION_TESTING 1
#include "transitions.c"
int hc_stock_control_attach_transition(HCStockControlSession *c,HCTransition *t){mark('A');assert(t->phase==HC_RUNNING);c->transition=t;return 0;}
int hc_stock_entry_start(HCStockEntryLaunch *e,HCStockGameSession *s,HCConsoleRuntime *r,HCConsoleGame *g,int fd,HCVerifiedLaunch *p,const char *pp,HCVerifiedLaunch *co,const char *cp,HCVerifiedLaunch *cfg,const char *cfp,int a,char *const env[]){(void)e;(void)r;(void)g;(void)fd;(void)p;(void)pp;(void)co;(void)cp;(void)cfg;(void)cfp;(void)a;(void)env;mark('L');s->save.phase=HC_STOCK_RUNNING;return 0;}
int hc_stock_control_step(HCStockControlSession *c,uint64_t now,int *status){(void)now;*status=0;mark('S');assert(c->transition);c->transition->phase=HC_EXITING;return 1;}
int hc_stock_entry_failed_start_poll(HCStockEntryLaunch *e,uint64_t now,int *status){(void)e;(void)now;(void)status;return -1;}
static void setup(HCStockGameplay *game,HCStockEntryLaunch *entry,HCStockGameSession *session,HCConsoleRuntime *runtime,HCConsoleGame *item,HCStockControlSession *control){
 *game=(HCStockGameplay)HC_STOCK_GAMEPLAY_INITIALIZER;*entry=(HCStockEntryLaunch)HC_STOCK_ENTRY_LAUNCH_INITIALIZER;*session=(HCStockGameSession)HC_STOCK_GAME_SESSION_INITIALIZER;
 *runtime=(HCConsoleRuntime)HC_CONSOLE_RUNTIME_INITIALIZER;*item=(HCConsoleGame)HC_CONSOLE_GAME_INITIALIZER;*control=(HCStockControlSession)HC_STOCK_CONTROL_SESSION_INITIALIZER;
 session->save.phase=HC_STOCK_PREPARED;entry->ready=1;entry->session=session;entry->runtime=runtime;entry->game=item;entry->control=control;control->save=&session->save;
 item->command.manager.present=(1u<<HC_WAIT)|(1u<<HC_START)|(1u<<HC_FINISH);item->command.manager.wait_fd=11;item->command.manager.start_fd=13;item->command.manager.finish_fd=14;
}
int main(void){
 HCStockGameplay game;HCStockEntryLaunch entry;HCStockGameSession session;HCConsoleRuntime runtime;HCConsoleGame item;HCStockControlSession control;HCStockLaunchSpec spec={0};int status=0;
 HCTransition transition={11,13,14,HC_INITIAL};setup(&game,&entry,&session,&runtime,&item,&control);
 assert(!hc_stock_gameplay_prepare(&game,&entry));assert(hc_stock_gameplay_start(&game,&spec)<0&&game.phase==HC_GAMEPLAY_PREPARED&&!used);
 transition.wait=12;assert(hc_stock_gameplay_bind_transition(&game,&transition)<0);transition.wait=11;
 for(int i=0;i<3;i++){invalid_fds=(int[]){11,13,14}[i];assert(hc_stock_gameplay_bind_transition(&game,&transition)<0&&!used&&!game.transition);}
 invalid_fds=0;assert(!hc_stock_gameplay_bind_transition(&game,&transition));
 for(int i=0;i<3;i++){invalid_fds=(int[]){11,13,14}[i];assert(hc_stock_gameplay_start(&game,&spec)<0&&game.phase==HC_GAMEPLAY_PREPARED&&!used);}
 invalid_fds=0;
 item.command.manager.wait_fd=12;
 assert(hc_stock_gameplay_start(&game,&spec)<0&&game.phase==HC_GAMEPLAY_PREPARED&&!used);
 item.command.manager.wait_fd=11;transition.start=12;
 assert(hc_stock_gameplay_start(&game,&spec)<0&&game.phase==HC_GAMEPLAY_PREPARED&&!used);
 transition.start=13;assert(!hc_stock_gameplay_start(&game,&spec));
 assert(!strcmp(order,"WAL"));assert(hc_stock_gameplay_poll(&game,1,&status)==1);assert(!hc_stock_gameplay_finish(&game));
 assert(!strcmp(order,"WALSPF")&&transition.phase==HC_COMPLETE);
 used=0;order[0]=0;wait_fail=1;transition=(HCTransition){11,13,14,HC_INITIAL};setup(&game,&entry,&session,&runtime,&item,&control);
 assert(!hc_stock_gameplay_prepare(&game,&entry));assert(!hc_stock_gameplay_bind_transition(&game,&transition));
 assert(hc_stock_gameplay_start(&game,&spec)<0&&game.phase==HC_GAMEPLAY_RECOVERY&&!strcmp(order,"W"));
 used=0;order[0]=0;wait_fail=0;finish_fail=1;transition=(HCTransition){11,13,14,HC_INITIAL};setup(&game,&entry,&session,&runtime,&item,&control);
 assert(!hc_stock_gameplay_prepare(&game,&entry));assert(!hc_stock_gameplay_bind_transition(&game,&transition));assert(!hc_stock_gameplay_start(&game,&spec));
 assert(hc_stock_gameplay_poll(&game,1,&status)==1);assert(hc_stock_gameplay_finish(&game)<0&&game.phase==HC_GAMEPLAY_RECOVERY&&!strcmp(order,"WALSPF"));
 used=0;order[0]=0;finish_fail=0;save_fail=1;transition=(HCTransition){11,13,14,HC_INITIAL};setup(&game,&entry,&session,&runtime,&item,&control);
 assert(!hc_stock_gameplay_prepare(&game,&entry));assert(!hc_stock_gameplay_bind_transition(&game,&transition));assert(!hc_stock_gameplay_start(&game,&spec));
 assert(hc_stock_gameplay_poll(&game,1,&status)==1);assert(hc_stock_gameplay_finish(&game)==-2&&game.phase==HC_GAMEPLAY_RECOVERY&&!strcmp(order,"WALSP"));
 assert(transition.phase==HC_EXITING);
 used=0;order[0]=0;save_fail=0;clock_calls=0;clock_fail=0;transition=(HCTransition){11,13,14,HC_INITIAL};setup(&game,&entry,&session,&runtime,&item,&control);
 assert(!hc_stock_gameplay_prepare(&game,&entry));assert(!hc_stock_gameplay_enable_time(&game));assert(hc_stock_gameplay_enable_time(&game)<0);
 assert(!hc_stock_gameplay_bind_transition(&game,&transition));assert(!hc_stock_gameplay_start(&game,&spec));
 assert(hc_stock_gameplay_poll(&game,1,&status)==1&&!strcmp(order,"WACLSC"));
 assert(game.clock_started&&game.clock_stopped&&game.clock_start.seconds==10&&game.clock_end.seconds==53);
 used=0;order[0]=0;clock_calls=0;clock_fail=1;transition=(HCTransition){11,13,14,HC_INITIAL};setup(&game,&entry,&session,&runtime,&item,&control);
 assert(!hc_stock_gameplay_prepare(&game,&entry)&&!hc_stock_gameplay_enable_time(&game)&&!hc_stock_gameplay_bind_transition(&game,&transition));
 assert(hc_stock_gameplay_start(&game,&spec)<0&&game.phase==HC_GAMEPLAY_RECOVERY&&!strcmp(order,"WAC"));
 used=0;order[0]=0;clock_calls=0;clock_fail=2;transition=(HCTransition){11,13,14,HC_INITIAL};setup(&game,&entry,&session,&runtime,&item,&control);
 assert(!hc_stock_gameplay_prepare(&game,&entry)&&!hc_stock_gameplay_enable_time(&game)&&!hc_stock_gameplay_bind_transition(&game,&transition));
 assert(!hc_stock_gameplay_start(&game,&spec));assert(hc_stock_gameplay_poll(&game,1,&status)<0&&game.phase==HC_GAMEPLAY_RECOVERY&&!strcmp(order,"WACLSC"));
 return 0;
}
