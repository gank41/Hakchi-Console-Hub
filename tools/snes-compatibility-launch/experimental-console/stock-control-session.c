#include "stock-control-session.h"
#include <errno.h>
static void reject_completed_save(HCStockSaveSession *s){
 if(s&&(s->phase==HC_STOCK_REAPED_CLEAN||s->phase==HC_STOCK_REAPED_NO_SRAM))s->phase=HC_STOCK_FAILED;
}
static int reset_bound(const HCStockControlSession *c){return c&&((c->manager_mode==1&&!c->reset&&c->manager_probe)||(c->manager_mode==0&&c->reset&&!c->manager_probe));}
static int poll_reset(HCStockControlSession *c){
 if(c->reset)return hc_stock_reset_poll(c->reset);
 int result=c->manager_probe();if(result>0)c->manager_reset=1;return result;
}
static int bind_save(HCStockControlSession *c,HCStockResetInput *r,HCStockSaveSession *s,int phase,int manager,int (*probe)(void)){
 if(!c||c->reset||c->power||c->save||c->transition||c->screenshot||c->state||c->capture_kind||c->capturing||c->capture_deadline||c->capture_last||c->manager_reset||c->manager_mode||c->manager_probe||c->started||c->failed||c->finished||c->reason!=HC_STOCK_CONTROL_NONE||
    c->exit_owner.save||c->exit_owner.phase||c->exit_owner.deadline||c->exit_owner.last||c->exit_owner.timed_out||c->exit_owner.kill_sent||
    (manager?(r!=NULL||!probe):(probe||!r||r->fd<3||!r->key||r->failed))||!s||s->phase!=phase){errno=EINVAL;return -1;}
 c->reset=r;c->save=s;c->manager_mode=manager;c->manager_probe=probe;return 0;
}
int hc_stock_control_prepare(HCStockControlSession *c,HCStockResetInput *r,HCStockSaveSession *s){return bind_save(c,r,s,HC_STOCK_PREPARED,0,NULL);}
int hc_stock_control_init(HCStockControlSession *c,HCStockResetInput *r,HCStockSaveSession *s){return bind_save(c,r,s,HC_STOCK_RUNNING,0,NULL);}
int hc_stock_control_prepare_manager(HCStockControlSession *c,HCStockSaveSession *s,int (*probe)(void)){return bind_save(c,NULL,s,HC_STOCK_PREPARED,1,probe);}
int hc_stock_control_attach_power(HCStockControlSession *c,HCStockPowerInput *p){
 if(!reset_bound(c)||!c->save||c->started||c->finished||c->power||!p||p->fd<3||(c->reset&&p->fd==c->reset->fd)||p->failed||p->triggered||p->used||p->code>767||(p->type!=1&&p->type!=5)||p->value>1){errno=EINVAL;return -1;}
 c->power=p;return 0;
}
int hc_stock_control_attach_screenshot(HCStockControlSession *c,HCStockScreenshotCapture *shot){
 if(!reset_bound(c)||!c->save||c->started||c->failed||c->finished||c->screenshot||shot==c->state||!shot||!shot->context||!shot->begin||!shot->poll){errno=EINVAL;return -1;}
 c->screenshot=shot;return 0;
}
int hc_stock_control_attach_state(HCStockControlSession *c,HCStockScreenshotCapture *state){
 if(!reset_bound(c)||!c->save||c->started||c->failed||c->finished||c->state||!state||state==c->screenshot||!state->context||!state->begin||!state->poll){errno=EINVAL;return -1;}
 c->state=state;return 0;
}
static int start_capture(HCStockControlSession *c,HCStockScreenshotCapture *op,int kind,uint64_t now){
 if(!op||!op->context||!op->begin||!op->poll||now>UINT64_MAX-5000||op->begin(op->context,c->save)){c->failed=1;return -1;}
 c->capturing=1;c->capture_kind=kind;c->capture_last=now;c->capture_deadline=now+5000;return 0;
}
static int request_exit(HCStockControlSession *c,uint64_t now){
 if(!c->failed&&c->transition&&hc_transition_begin_exit(c->transition))c->failed=1;
 int r=hc_stock_exit_request(&c->exit_owner,c->save,now,10000);
 if(c->failed)c->exit_owner.timed_out=1;
 if(r){c->failed=1;c->exit_owner.timed_out=1;if(c->exit_owner.phase!=1){c->finished=1;reject_completed_save(c->save);return -1;}}
 return 0;
}
int hc_stock_control_attach_transition(HCStockControlSession *c,HCTransition *transition){
 if(!reset_bound(c)||!c->save||c->save->phase!=HC_STOCK_PREPARED||c->started||c->finished||c->failed||c->transition||!transition||transition->phase!=HC_RUNNING){errno=EINVAL;return -1;}
 c->transition=transition;return 0;
}
int hc_stock_control_abort(HCStockControlSession *c,uint64_t now){
 if(!reset_bound(c)||!c->power||!c->save||c->started||c->failed||c->finished||c->reason!=HC_STOCK_CONTROL_NONE||c->save->phase!=HC_STOCK_RUNNING){errno=EINVAL;return -1;}
 /* A startup failure is never converted into a clean save, even when the
  * child later exits normally. Keep the owner alive through the grace period. */
 c->started=1;c->failed=1;
 if(c->transition)(void)hc_transition_begin_exit(c->transition);
 if(hc_stock_exit_request(&c->exit_owner,c->save,now,10000)&&c->exit_owner.phase!=1){c->finished=1;reject_completed_save(c->save);return -1;}
 return 0;
}
int hc_stock_control_manager_reset(HCStockControlSession *c){
 if(!reset_bound(c)||!c->save||c->failed||c->finished||(c->save->phase!=HC_STOCK_RUNNING&&!(c->manager_mode&&c->save->phase==HC_STOCK_PREPARED))){errno=EINVAL;return -1;}
 c->manager_reset=1;return 0;
}
int hc_stock_control_step(HCStockControlSession *c,uint64_t now,int *status){
 if(!reset_bound(c)||!c->save||!status||c->finished||(!c->started&&c->save->phase!=HC_STOCK_RUNNING)){errno=EINVAL;return -1;}
 if(c->capturing){
  int reset=poll_reset(c),power=c->power?hc_stock_power_poll(c->power):0;
  if(reset<0||power<0||now<c->capture_last)c->failed=1;
  else if(power>0)c->reason=HC_STOCK_CONTROL_POWER;
  c->capture_last=now;
  int child=hc_stock_save_poll(c->save,status);
  if(child){c->capturing=0;c->failed=c->finished=1;reject_completed_save(c->save);errno=EIO;return -1;}
  HCStockScreenshotCapture *op=c->capture_kind==1?c->state:c->capture_kind==2?c->screenshot:NULL;
  int result=c->failed||!op||!op->poll||now>=c->capture_deadline?-1:op->poll(op->context,c->save,now);
  if(!result)return 0;
  c->capturing=0;if(result!=1)c->failed=1;
  else if(c->capture_kind==1&&c->screenshot){if(!start_capture(c,c->screenshot,2,now))return 0;}
  c->capture_kind=0;
  return request_exit(c,now);
 }
 if(c->started){int reset=poll_reset(c),power=c->power?hc_stock_power_poll(c->power):0;if(reset<0||power<0){c->failed=1;c->exit_owner.timed_out=1;}else if(power>0)c->reason=HC_STOCK_CONTROL_POWER;int r=hc_stock_exit_poll(&c->exit_owner,now,status);if(r){c->finished=1;if(r==1&&!c->failed)return 1;c->failed=1;reject_completed_save(c->save);errno=EIO;return -1;}return 0;}
 int reset=poll_reset(c);
 int power=c->power?hc_stock_power_poll(c->power):0;
 if(reset||power||c->manager_reset){
  c->started=1;if(reset<0||power<0)c->failed=1;else c->reason=power>0?HC_STOCK_CONTROL_POWER:HC_STOCK_CONTROL_RESET;
  if(!c->failed&&(c->state||c->screenshot)){
   if(!start_capture(c,c->state?c->state:c->screenshot,c->state?1:2,now))return 0;
  }
  return request_exit(c,now);
 }
 int r=hc_stock_save_poll(c->save,status);
 if(r){c->failed=c->finished=1;reject_completed_save(c->save);errno=EIO;return -1;}return 0;
}
int hc_stock_control_refresh_finished(HCStockControlSession *c){
 if(!reset_bound(c)||!c->save||!c->started||!c->finished||c->failed||c->exit_owner.save!=c->save||c->exit_owner.phase!=2||c->exit_owner.timed_out||c->exit_owner.kill_sent||
    (c->reason!=HC_STOCK_CONTROL_RESET&&c->reason!=HC_STOCK_CONTROL_POWER)){errno=EINVAL;return -1;}
 int reset=poll_reset(c),power=c->power?hc_stock_power_poll(c->power):0;
 if(reset<0||power<0||(c->reset&&c->reset->used)||(c->power&&c->power->used)){c->failed=1;reject_completed_save(c->save);errno=EIO;return -1;}
 if(power>0)c->reason=HC_STOCK_CONTROL_POWER;
 return 0;
}
