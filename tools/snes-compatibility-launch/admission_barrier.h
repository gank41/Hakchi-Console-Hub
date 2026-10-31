#ifndef HAKCHI_ADMISSION_BARRIER_H
#define HAKCHI_ADMISSION_BARRIER_H
#include <pthread.h>
typedef struct {pthread_mutex_t lock;unsigned active;int closing,initialized;} HCAdmission;
typedef struct {HCAdmission *owner;int active;} HCAdmissionLease;
#define HC_ADMISSION_INITIALIZER {0}
#define HC_ADMISSION_LEASE_INITIALIZER {0}
/* Initialize with HC_ADMISSION_INITIALIZER before any producer starts.
 * Producers must enter BEFORE accessing any teardown-sensitive objects and
 * retain a unique, non-copied lease until all such access and queue admission
 * ends. close denies new entrants; ready is true only after all leases leave.
 * Caller owns gate lifetime and must stop/join all would-be entrants before
 * destroy. This primitive cannot discover unregistered producers. */
int hc_admission_init(HCAdmission *);
int hc_admission_enter(HCAdmission *,HCAdmissionLease *);
int hc_admission_leave(HCAdmissionLease *);
int hc_admission_close(HCAdmission *);
/* Returns exactly 1 when drained, 0 while active or on any error. */
int hc_admission_ready(HCAdmission *);
int hc_admission_destroy(HCAdmission *);
#endif
