#ifndef HC_STOCK_RESET_DISCOVERY_H
#define HC_STOCK_RESET_DISCOVERY_H
#include <stdint.h>
#include <sys/types.h>
/* Returns a nonblocking owned device descriptor for exactly one matching
 * kernel device name and supported key. Caller must authenticate the platform,
 * trusted /dev/input directory and expected mapping, keep it alive, and close
 * the descriptor. No device input is grabbed or read here. */
int hc_stock_reset_discover(int dev_directory,uid_t owner,const char *expected_name,uint16_t key);
#endif
