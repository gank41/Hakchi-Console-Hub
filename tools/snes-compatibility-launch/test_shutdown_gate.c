#include "shutdown_gate.h"
#include <assert.h>
#include <stddef.h>
int main(void) {
 HCShutdownGate g=HC_SHUTDOWN_GATE_INITIALIZER;
 assert(hc_shutdown_tick(&g,0,1,100,10)==HC_SHUTDOWN_RUNNING);
 assert(hc_shutdown_tick(&g,1,0,101,10)==HC_SHUTDOWN_WAIT);
 assert(hc_shutdown_tick(&g,0,0,105,10)==HC_SHUTDOWN_WAIT);
 assert(hc_shutdown_tick(&g,0,1,106,10)==HC_SHUTDOWN_READY);
 assert(hc_shutdown_tick(&g,0,0,107,10)==HC_SHUTDOWN_WAIT);
 assert(hc_shutdown_tick(&g,0,1,108,10)==HC_SHUTDOWN_READY);
 HCShutdownGate timeout=HC_SHUTDOWN_GATE_INITIALIZER;
 assert(hc_shutdown_tick(&timeout,1,0,100,5)==HC_SHUTDOWN_WAIT);
 assert(hc_shutdown_tick(&timeout,0,0,105,5)==HC_SHUTDOWN_TIMEOUT);
 assert(hc_shutdown_tick(&timeout,0,1,106,5)==HC_SHUTDOWN_TIMEOUT);
 HCShutdownGate clock=HC_SHUTDOWN_GATE_INITIALIZER;
 assert(hc_shutdown_tick(&clock,1,0,100,10)==HC_SHUTDOWN_WAIT);
 assert(hc_shutdown_tick(&clock,0,0,99,10)==HC_SHUTDOWN_TIMEOUT);
 HCShutdownGate failed_clock=HC_SHUTDOWN_GATE_INITIALIZER;
 assert(hc_shutdown_tick(&failed_clock,1,0,0,10)==HC_SHUTDOWN_TIMEOUT);
 assert(hc_shutdown_tick(NULL,1,1,0,1)==HC_SHUTDOWN_TIMEOUT);
 return 0;
}
