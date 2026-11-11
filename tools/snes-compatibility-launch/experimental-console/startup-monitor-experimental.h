#ifndef HC_STARTUP_MONITOR_EXPERIMENTAL_H
#define HC_STARTUP_MONITOR_EXPERIMENTAL_H
#include <stdint.h>
#include <sys/types.h>
/* Experimental only. Caller exclusively owns a dedicated nonblocking read end,
 * creates/authenticates the writer and unique session, owns child as its
 * unreaped direct child, and prevents ALL concurrent wait/reap and fd access.
 * No SIGCHLD ignore/SA_NOCLDWAIT. Child must close its writer after reporting
 * and remain alive until caller assumes supervision. No other process may write
 * the channel. This function neither closes fds nor kills/reaps the child.
 * An observed live child can exit immediately after return; success is only a
 * sampled observation, not a health guarantee. Ownership must continue beyond
 * return. Output remains untouched on failure. A valid FAILED frame is failure.
 * timeout_ms is strictly positive. */
int hc_monitor_startup(int fd,pid_t child,const uint8_t session[16],uint64_t epoch,unsigned timeout_ms,int *status_out);
/* Same ownership and liveness contract. Returns 0 for an exact OK or FAILED
 * report and stores its status. -1 means no trustworthy report; output is
 * unchanged. FAILED is not evidence that workers stopped or recovery is safe. */
int hc_monitor_startup_result(int fd,pid_t child,const uint8_t session[16],uint64_t epoch,unsigned timeout_ms,int *status_out);
/* Dedicated exit-failure channel, same ownership and liveness conditions.
 * Only an exact FAILED frame returns success; absence, timeout or an OK frame
 * remains an uncertain failure. This does not stop or reap the child. */
int hc_monitor_exit_failure(int fd,pid_t child,const uint8_t session[16],uint64_t epoch,unsigned timeout_ms);
#endif
