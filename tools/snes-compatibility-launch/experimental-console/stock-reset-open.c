#define _POSIX_C_SOURCE 200809L
#include "stock-reset-open.h"
#include "stock-reset-discovery.h"
#include <errno.h>
#include <unistd.h>
int hc_stock_reset_open_named(HCStockOpenedReset *r,int directory,uid_t owner,const char *name,uint16_t key){
 if(!r||r->owned!=-1||r->input.fd!=-1){errno=EINVAL;return -1;}
 int fd=hc_stock_reset_discover(directory,owner,name,key);if(fd<0)return -1;
 if(hc_stock_reset_init(&r->input,fd,key)){int saved=errno;(void)close(fd);errno=saved;return -1;}
 r->owned=fd;return 0;
}
int hc_stock_reset_close_named(HCStockOpenedReset *r){
 if(!r||r->owned<3||r->input.fd!=r->owned){errno=EINVAL;return -1;}
 int fd=r->owned;r->owned=-1;r->input=(HCStockResetInput)HC_STOCK_RESET_INPUT_INITIALIZER;return close(fd);
}
