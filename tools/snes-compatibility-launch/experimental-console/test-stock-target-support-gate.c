#include "stock-gameplay.h"
int hc_stock_manager_state_preflight(HCStockManagerState *o,HCStockGameSession *g,HCConsoleRuntime *r,HCConsoleGame *m,int p){(void)o;(void)g;(void)r;(void)m;(void)p;return -1;}
int hc_stock_selected_state_recheck(HCStockSelectedState *s){(void)s;return -1;}
int hc_console_game_check_manager_record_full(int fd,const HCLaunchRequest *r,const HCManagerCheckpointPaths *c,const HCManagerTimePaths *t){(void)fd;(void)r;(void)c;(void)t;return -1;}
int hc_stock_time_seed_recheck(HCStockTimeSeed *seed,HCStockGameSession *s,HCConsoleRuntime *r,HCConsoleGame *g,int d){(void)seed;(void)s;(void)r;(void)g;(void)d;return -1;}
int hc_stock_time_seed_backup_recheck(HCStockTimeSeed *seed,HCStockGameSession *s,HCConsoleRuntime *r){(void)seed;(void)s;(void)r;return -1;}
int hc_stock_game_autoload_ready(HCStockGameSession *s,int a){(void)s;(void)a;return 0;}
int hc_transition_init(HCTransition *t,int w,int a,int f){(void)t;(void)w;(void)a;(void)f;return -1;}
int hc_transition_before_first_frame(HCTransition *t){(void)t;return -1;}
int hc_transition_finish_exit(HCTransition *t){(void)t;return -1;}
int hc_stock_control_attach_transition(HCStockControlSession *c,HCTransition *t){(void)c;(void)t;return -1;}

#include "console-support.h"
#include <assert.h>
static int launches;
int hc_verified_launch_recheck(HCVerifiedLaunch *v){(void)v;return 0;}
int hc_stock_entry_start(HCStockEntryLaunch *e,HCStockGameSession *s,HCConsoleRuntime *r,HCConsoleGame *g,int t,HCVerifiedLaunch *p,const char *pp,HCVerifiedLaunch *co,const char *cp,HCVerifiedLaunch *cfg,const char *cfp,int a,char *const envp[]){
 (void)e;(void)s;(void)r;(void)g;(void)t;(void)p;(void)pp;(void)co;(void)cp;(void)cfg;(void)cfp;(void)a;(void)envp;launches++;return 0;
}
int main(void){
 HCStockEntryLaunch entry={0};HCStockGameSession session={0};HCStockControlSession control={0};
 HCStockGameplay game=HC_STOCK_GAMEPLAY_INITIALIZER;HCStockLaunchSpec spec={0};
 entry.session=&session;entry.control=&control;game.entry=&entry;game.session=&session;game.control=&control;game.phase=HC_GAMEPLAY_PREPARED;
 assert(hc_stock_gameplay_start(&game,&spec)==-1);assert(launches==0);
 HCConsoleSupport support=HC_CONSOLE_SUPPORT_INITIALIZER;spec.support=&support;
 spec.program=&support.files[1];spec.core=&support.files[0];
 spec.program_path="/mnt/swifthakchi/snes-compat/retroarch";spec.core_path="/mnt/swifthakchi/snes-compat/snes9x2010_libretro.so";
 assert(hc_stock_gameplay_start(&game,&spec)==-1);assert(launches==0);
 return 0;
}
