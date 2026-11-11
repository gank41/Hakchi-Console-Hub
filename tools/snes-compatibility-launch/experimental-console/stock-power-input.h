#ifndef HC_STOCK_POWER_INPUT_H
#define HC_STOCK_POWER_INPUT_H
#include <stdint.h>
#include <stddef.h>
/* Mapping is supplied from an authenticated platform-specific observation.
 * This does not infer power events or authenticate the device. */
typedef struct {int fd;uint16_t type,code;uint32_t value;unsigned char pending[16];size_t used;int triggered,failed;} HCStockPowerInput;
#define HC_STOCK_POWER_INPUT_INITIALIZER {-1,0,0,0,{0},0,0,0}
int hc_stock_power_init(HCStockPowerInput *,int,uint16_t,uint16_t,uint32_t);
/* Exhausting the read budget fails closed; a partial record remains in used. */
int hc_stock_power_poll(HCStockPowerInput *);
#endif
