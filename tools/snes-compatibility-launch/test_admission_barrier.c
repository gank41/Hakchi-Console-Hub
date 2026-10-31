#include "admission_barrier.h"
#include <assert.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
static HCAdmission gate;static atomic_int entered,release_worker;
static void *worker(void *unused){(void)unused;HCAdmissionLease lease=HC_ADMISSION_LEASE_INITIALIZER;
 assert(hc_admission_enter(&gate,&lease)==0);atomic_store(&entered,1);
 while(!atomic_load(&release_worker))sched_yield();assert(hc_admission_leave(&lease)==0);return NULL;}
int main(void){assert(hc_admission_ready(NULL)==0);HCAdmission unused=HC_ADMISSION_INITIALIZER;assert(hc_admission_ready(&unused)==0);
 assert(hc_admission_init(&gate)==0);pthread_t t;assert(pthread_create(&t,NULL,worker,NULL)==0);
 while(!atomic_load(&entered))sched_yield();assert(hc_admission_close(&gate)==0);assert(hc_admission_ready(&gate)==0);
 HCAdmissionLease late=HC_ADMISSION_LEASE_INITIALIZER;assert(hc_admission_enter(&gate,&late)<0);
 assert(hc_admission_destroy(&gate)<0);atomic_store(&release_worker,1);assert(pthread_join(t,NULL)==0);
 assert(hc_admission_ready(&gate)==1);assert(hc_admission_leave(&late)<0);assert(hc_admission_destroy(&gate)==0);return 0;}
