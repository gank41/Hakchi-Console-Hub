#ifndef HAKCHI_SHUTDOWN_GATE_H
#define HAKCHI_SHUTDOWN_GATE_H
#include <stdint.h>
typedef enum {HC_SHUTDOWN_RUNNING,HC_SHUTDOWN_WAIT,HC_SHUTDOWN_READY,HC_SHUTDOWN_TIMEOUT} HCShutdownResult;
typedef struct {uint64_t start,last,limit;int pending,terminal;} HCShutdownGate;
#define HC_SHUTDOWN_GATE_INITIALIZER {0}
/* Main-thread only. now and timeout use the same monotonic units. Latches a
 * one-shot exit request. Timeout or backwards time fails closed and never
 * authorizes teardown, even if ready changes later. The caller must keep
 * servicing the queue, preserve all callback state and notify its supervisor
 * on timeout; this gate does not cancel tasks, close files or kill a child.
 * READY is only a point-in-time result: the caller must separately freeze
 * submissions before teardown and keep the queue lifetime stable. */
HCShutdownResult hc_shutdown_tick(HCShutdownGate *,int exit_requested,int ready,uint64_t now,uint64_t timeout);
#endif
