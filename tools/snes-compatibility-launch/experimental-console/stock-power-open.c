#define _POSIX_C_SOURCE 200809L
#include "stock-power-open.h"
#include "stock-reset-discovery.h"
#include <errno.h>
#include <unistd.h>
int hc_stock_power_open_named(HCStockOpenedPower *p,int directory,uid_t owner,const char *name,uint16_t key,uint32_t value){
 if(!p||p->owned!=-1||p->input.fd!=-1||value>1){errno=EINVAL;return -1;}
 int fd=hc_stock_reset_discover(directory,owner,name,key);if(fd<0)return -1;
 if(hc_stock_power_init(&p->input,fd,1,key,value)){int saved=errno;(void)close(fd);errno=saved;return -1;}
 p->owned=fd;return 0;
}
int hc_stock_power_close_named(HCStockOpenedPower *p){
 if(!p||p->owned<3||p->input.fd!=p->owned){errno=EINVAL;return -1;}
 int fd=p->owned;p->owned=-1;p->input=(HCStockPowerInput)HC_STOCK_POWER_INPUT_INITIALIZER;return close(fd);
}
