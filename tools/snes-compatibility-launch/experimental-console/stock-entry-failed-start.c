#include "stock-entry-start.h"
#include <errno.h>
/* This helper only owns the failed startup path. The caller retains every
 * object, handles uncertain ownership, and keeps the original error separate. */
int hc_stock_entry_failed_start_poll(HCStockEntryLaunch *entry,uint64_t now,int *status){
 if(!entry||entry->ready||!entry->start_failed||!entry->session||!entry->control||!status||
    entry->control->save!=&entry->session->save||entry->control->finished||
    (entry->control->started&&!entry->control->failed)) {errno=EINVAL;return -1;}
 HCStockControlSession *control=entry->control;
 if(!control->started&&hc_stock_control_abort(control,now))return -1;
 int observed=-1;int result=hc_stock_control_step(control,now,&observed);
 if(!result)return 0;
 HCStockSaveSession *save=control->save;
 /* A child which exits cleanly is deliberately downgraded to FAILED by the
  * failed control owner. An actual wait status distinguishes it from a lost
  * child or descriptor-close failure, neither of which proves a reap. */
 if(result<0&&control->finished&&control->failed&&observed>=0&&
    (save->phase==HC_STOCK_REAPED_FAILED||save->phase==HC_STOCK_FAILED)&&
    save->child.pid==-1&&!save->child.reaped_pending&&!save->child_wait_unknown){*status=observed;return 1;}
 errno=EIO;return -1;
}
