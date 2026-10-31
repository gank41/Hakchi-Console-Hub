#include "shutdown_gate.h"
HCShutdownResult hc_shutdown_tick(HCShutdownGate *g,int exit_requested,int ready,uint64_t now,uint64_t timeout) {
 if(!g || (exit_requested!=0 && exit_requested!=1) || (ready!=0 && ready!=1)) return HC_SHUTDOWN_TIMEOUT;
 if(g->terminal==2) return HC_SHUTDOWN_TIMEOUT;
 if(!g->pending) {
  if(!exit_requested) return HC_SHUTDOWN_RUNNING;
  if(!timeout || !now) {g->terminal=2;return HC_SHUTDOWN_TIMEOUT;}
  g->pending=1;g->start=now;g->last=now;g->limit=timeout;
 }
 if(!now || now<g->last || now-g->start>=g->limit) {g->terminal=2;return HC_SHUTDOWN_TIMEOUT;}
 g->last=now;
 if(ready) return HC_SHUTDOWN_READY;
 return HC_SHUTDOWN_WAIT;
}
