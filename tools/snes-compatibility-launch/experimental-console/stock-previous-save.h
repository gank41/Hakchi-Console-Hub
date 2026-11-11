#ifndef HC_STOCK_PREVIOUS_SAVE_H
#define HC_STOCK_PREVIOUS_SAVE_H
#include "stock-entry-finalize.h"
/* A prelaunch snapshot binds prior save bytes or absence to one game session.
 * It lives only in memory: restart recovery must use the durable journal.
 * The caller authenticates paths and excludes uncooperative writers. */
typedef struct {HCStockGameSession *owner;unsigned char *bytes;size_t length;char game[12],digest[65];uint8_t token[16];uint64_t epoch;int present,ready;} HCStockPrevious;
#define HC_STOCK_PREVIOUS_INITIALIZER {NULL,NULL,0,{0},{0},{0},0,0,0}
int hc_stock_previous_capture(HCStockPrevious *,HCStockGameSession *);
/* Check that the captured prior bytes still belong to this exact session. */
int hc_stock_previous_validate(HCStockPrevious *,HCStockGameSession *);
int hc_stock_previous_finish(HCStockPrevious *,HCStockGameSession *,HCStockControlSession *);
void hc_stock_previous_clear(HCStockPrevious *);
#endif
