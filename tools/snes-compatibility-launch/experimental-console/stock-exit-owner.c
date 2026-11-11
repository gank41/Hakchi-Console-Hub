#include "stock-exit-owner.h"
#include <errno.h>
#include <signal.h>
#include <stdint.h>
int hc_stock_exit_request(HCStockExitOwner *o,HCStockSaveSession *s,uint64_t now,unsigned timeout){
 if(!o||!s||o->phase||s->phase!=HC_STOCK_RUNNING||!timeout||timeout>60000||now>UINT64_MAX-timeout){errno=EINVAL;return -1;}
 /* The save owner retains a child even if signal/verification fails. */
 o->save=s;o->deadline=now+timeout;o->last=now;o->phase=1;
 if(hc_stock_save_signal(s,SIGTERM)){if(s->phase!=HC_STOCK_RUNNING)o->phase=2;return -1;}return 0;
}
int hc_stock_exit_poll(HCStockExitOwner *o,uint64_t now,int *status){
 if(!o||o->phase!=1||!o->save||!status){errno=EINVAL;return -1;}
 if(now<o->last||now>=o->deadline)o->timed_out=1;o->last=now;
 int result=hc_stock_save_poll(o->save,status);
 if(result<0){o->phase=2;return -1;}
 if(result==1){o->phase=2;if(!o->timed_out&&(o->save->phase==HC_STOCK_REAPED_CLEAN||o->save->phase==HC_STOCK_REAPED_NO_SRAM))return 1;errno=EIO;return -1;}
 if(o->timed_out&&!o->kill_sent){
  if(!hc_stock_save_signal(o->save,SIGKILL))o->kill_sent=1;
  else if(o->save->phase!=HC_STOCK_RUNNING){o->phase=2;errno=EIO;return -1;}
 }
 return 0;
}
