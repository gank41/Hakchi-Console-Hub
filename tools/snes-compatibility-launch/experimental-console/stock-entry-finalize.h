#ifndef HC_STOCK_ENTRY_FINALIZE_H
#define HC_STOCK_ENTRY_FINALIZE_H
#include "stock-game-session.h"
#include "stock-control-session.h"
/* Publish a stopped game's SRAM and finish its journal in order. The caller
 * independently authenticates and retains the previous bytes (or verified
 * absence), controls the session and save paths, and stops all other writers.
 * A match against the session snapshot is only a consistency check, not
 * authentication. This function does not launch a game, remove a workspace,
 * or establish console power-loss durability.
 * Returns 0 only on completion; -1 is refusal or pre-publication failure;
 * -2 means publication may have occurred and recovery must inspect the
 * journal; -3 means the prior save remains active with retained recovery. */
int hc_stock_entry_publish_and_finish(HCStockGameSession *,HCStockControlSession *,const void *,size_t);
/* Complete a confirmed no-SRAM session without publishing a save. The same
 * independent prior-save/absence and stopped-writer requirements apply. */
int hc_stock_entry_finish_no_sram(HCStockGameSession *,HCStockControlSession *,const void *,size_t);
#endif
