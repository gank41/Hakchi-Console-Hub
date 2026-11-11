#ifndef HC_STOCK_RUNTIME_BRIDGE_H
#define HC_STOCK_RUNTIME_BRIDGE_H
#include "console-runtime.h"
#include "stock-game-session.h"
#include "size-probe-runner.h"
#include "stock-control-session.h"
/* Correlates one prepared runtime with one verified game/save session. Caller
 * must authenticate the game and control all descriptors and paths. This is
 * not a release, persistence, crash-recovery, or gameplay authorization. */
int hc_stock_game_prepare_runtime(HCStockGameSession *,HCConsoleRuntime *,HCConsoleGame *,int,const char *const [],const char *,int,int,const char *,size_t);
/* Consumes one successful probe for exactly this game and verified core. A
 * zero-size game uses a nominal stage size but may never publish SRAM. This
 * does not authenticate the probe result, frontend options, or console. */
int hc_stock_game_prepare_detected(HCStockGameSession *,HCConsoleRuntime *,HCConsoleGame *,int,const char *const [],const char *,int,int,const char *,HCSizeProbe *,HCVerifiedLaunch *);
/* In-process cleanup only after a finalized save session with no manager
 * checkpoint or screenshot request. Caller has authenticated the session and
 * original evidence, completed manager transitions, stopped all writers,
 * and holds exclusive access. This does not prove those conditions. */
int hc_stock_game_discard_finished_runtime(HCStockGameSession *,HCConsoleRuntime *,int,HCConsoleSupervisor *,HCConsoleGame *,HCStockControlSession *);
#endif
