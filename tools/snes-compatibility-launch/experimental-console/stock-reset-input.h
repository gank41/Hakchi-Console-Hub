#ifndef HC_STOCK_RESET_INPUT_H
#define HC_STOCK_RESET_INPUT_H
#include <stddef.h>
#include <stdint.h>
/* The caller authenticates the unique system-button device and reset key,
 * opens it nonblocking and retains exclusive descriptor ownership. This
 * parses 32-bit Linux input_event records; it does not discover a device,
 * claim a key mapping, read power input or authorize console launch. */
typedef struct {int fd;uint16_t key;unsigned char pending[16];size_t used;int pressed,failed;} HCStockResetInput;
#define HC_STOCK_RESET_INPUT_INITIALIZER {-1,0,{0},0,0,0}
int hc_stock_reset_init(HCStockResetInput *,int,uint16_t);
/* Returns 1 on a new RESET press, 0 if none, -1 on malformed/lost input.
 * Exhausting the bounded read budget fails closed; it does not report that
 * the stream is clear. A partial record remains pending in `used`. */
int hc_stock_reset_poll(HCStockResetInput *);
#endif
