#ifndef HC_STOCK_RESET_OPEN_H
#define HC_STOCK_RESET_OPEN_H
#include "stock-reset-input.h"
#include <sys/types.h>
/* Owner of the verified discovery descriptor. The caller authenticates the
 * platform, directory and key mapping and closes only after monitoring ends. */
typedef struct {HCStockResetInput input;int owned;} HCStockOpenedReset;
#define HC_STOCK_OPENED_RESET_INITIALIZER {HC_STOCK_RESET_INPUT_INITIALIZER,-1}
int hc_stock_reset_open_named(HCStockOpenedReset *,int,uid_t,const char *,uint16_t);
int hc_stock_reset_close_named(HCStockOpenedReset *);
#endif
