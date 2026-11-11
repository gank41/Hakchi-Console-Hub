#ifndef HC_RECOVERY_CLOCK_WIRE_H
#define HC_RECOVERY_CLOCK_WIRE_H
#include "recovery-observer.h"
/* The decoded evidence pointer borrows the original frame. The caller must
 * authenticate all inputs, original/current evidence, stopped writers and
 * exclusive access; matching a frame does not authorize any console write. */
typedef struct {HCLaunchRequest request;char workspace[44];HCRecoveryOriginal original;const unsigned char *evidence;size_t evidence_length;int current_present;const unsigned char *current;size_t current_length;uint64_t device,inode;HCIV2Kind intent_kind;} HCClockRecoveryRequest;
int hc_clock_recovery_decode(const void *,size_t,HCClockRecoveryRequest *);
/* Read-only selection inspection; it does not verify save evidence, stop
 * writers, authenticate a console or authorize any recovery operation. */
int hc_clock_recovery_inspect(int,const char *,uid_t,const void *,size_t,HCRecoveryObservation *);
int hc_clock_recovery_execute(int,const char *,uid_t,const void *,size_t);
typedef HCClockRecoveryRequest HCBatteryRecoveryRequest;
int hc_battery_recovery_decode(const void *,size_t,HCBatteryRecoveryRequest *);
int hc_battery_recovery_inspect(int,const char *,uid_t,const void *,size_t,HCRecoveryObservation *);
int hc_battery_recovery_execute(int,const char *,uid_t,const void *,size_t);
#endif
