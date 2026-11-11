#ifndef HC_STOCK_CONFIG_H
#define HC_STOCK_CONFIG_H
#include "verified-launch.h"
/* Exact prototype config: caller still authenticates the frontend/core, owns
 * the stage directory exclusively and supplies a verified config descriptor.
 * This does not establish driver compatibility or permit console launch. */
/* Create only a new private stage config. A failed creation may retain the
 * file for inspection; caller owns the stage and excludes other writers. */
int hc_stock_config_create(HCVerifiedLaunch *,int,const char *,int);
int hc_stock_config_validate(HCVerifiedLaunch *,int,const char *,int);
/* Screenshot mode requires the caller-owned private shots child directory. */
int hc_stock_config_create_screenshot(HCVerifiedLaunch *,int,const char *,int);
int hc_stock_config_validate_screenshot(HCVerifiedLaunch *,int,const char *,int);
#endif
