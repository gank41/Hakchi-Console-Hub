#ifndef HC_STOCK_POWER_OPEN_H
#define HC_STOCK_POWER_OPEN_H
#include "stock-power-input.h"
#include <sys/types.h>
/* The caller authenticates the console model, directory and observed mapping. */
typedef struct {HCStockPowerInput input;int owned;} HCStockOpenedPower;
#define HC_STOCK_OPENED_POWER_INITIALIZER {HC_STOCK_POWER_INPUT_INITIALIZER,-1}
int hc_stock_power_open_named(HCStockOpenedPower *,int,uid_t,const char *,uint16_t,uint32_t);
int hc_stock_power_close_named(HCStockOpenedPower *);
#endif
