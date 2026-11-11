#ifndef HC_STOCK_EXIT_OWNER_H
#define HC_STOCK_EXIT_OWNER_H
#include "stock-save-session.h"
#include <stdint.h>
/* Caller supplies monotonic milliseconds, remains sole child owner and keeps
 * all session resources alive. A failed or timed-out exit retains recovery. */
typedef struct {HCStockSaveSession *save;uint64_t deadline,last;int phase,timed_out,kill_sent;} HCStockExitOwner;
#define HC_STOCK_EXIT_OWNER_INITIALIZER {NULL,0,0,0,0,0}
int hc_stock_exit_request(HCStockExitOwner *,HCStockSaveSession *,uint64_t,unsigned);
/* 0 pending, 1 clean/no-SRAM exit, -1 failure. Errors can leave an owned
 * child that needs separate supervision; never assume failure means reaped.
 * Continue polling after a timeout until the child is reaped. */
int hc_stock_exit_poll(HCStockExitOwner *,uint64_t,int *);
#endif
