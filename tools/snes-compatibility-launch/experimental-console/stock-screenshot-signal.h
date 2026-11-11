#ifndef HC_STOCK_SCREENSHOT_SIGNAL_H
#define HC_STOCK_SCREENSHOT_SIGNAL_H
#include "stock-control-session.h"
#include <errno.h>
#include <signal.h>
/* The single-threaded owner must maintain this process-wide policy until
 * all screenshot writers stop. Checking it cannot exclude later changes. */
static inline int hc_stock_screenshot_signal_ready(const HCStockControlSession *control){
 if(!control||!control->save){errno=EINVAL;return -1;}
 if(!!control->screenshot!=!!control->save->screenshot_enabled){errno=EINVAL;return -1;}
 if(control->state&&(!control->state->context||!control->state->begin||!control->state->poll)){errno=EINVAL;return -1;}
 if(control->screenshot&&(!control->screenshot->context||!control->screenshot->begin||!control->screenshot->poll||control->state==control->screenshot)){errno=EINVAL;return -1;}
 if(!control->screenshot&&!control->state)return 0;
 struct sigaction action;
 if(sigaction(SIGPIPE,NULL,&action))return -1;
 if(action.sa_handler!=SIG_IGN){errno=EPERM;return -1;}
 return 0;
}
#endif
