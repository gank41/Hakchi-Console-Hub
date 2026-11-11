#ifndef HC_STOCK_MANAGER_STATE_H
#define HC_STOCK_MANAGER_STATE_H
#include "stock-state-capture.h"
#include "console-game.h"

/* Experimental single-use output to a separately held manager directory.
 * The caller authenticates the manager, paths and console, excludes writers,
 * and retains every object until completion or recovery. Existing targets are
 * never replaced. A failure may leave records and requires reconciliation. */
typedef struct {int attempted,published;HCAutosaveTarget target;char path[1024];} HCStockManagerState;
#define HC_STOCK_MANAGER_STATE_INITIALIZER {0,0,HC_AUTOSAVE_TARGET_INITIALIZER,{0}}
int hc_stock_manager_state_preflight(HCStockManagerState *,HCStockGameSession *,HCConsoleRuntime *,HCConsoleGame *,int);
int hc_stock_manager_state_publish(HCStockManagerState *,HCStockGameSession *,HCConsoleRuntime *,HCConsoleGame *,HCStockControlSession *,HCStockStateReceipt *,HCStockStateArchive *,const HCStateBytes *,int);
int hc_stock_manager_state_recheck(HCStockManagerState *,HCStockGameSession *,HCConsoleRuntime *,HCConsoleGame *,HCStockControlSession *,HCStockStateReceipt *,HCStockStateArchive *,const HCStateBytes *,int);
int hc_stock_manager_state_close(HCStockManagerState *);
#endif
