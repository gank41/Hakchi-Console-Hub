#ifndef HC_NONCE_SEQUENCE_H
#define HC_NONCE_SEQUENCE_H
#include <pthread.h>
#include <stdint.h>
#include <sys/types.h>
typedef struct {pthread_mutex_t lock;uint8_t prefix[12];uint32_t counter;int active;pid_t process;} HCNonceSequence;
#define HC_NONCE_SEQUENCE_INITIALIZER {0}
/* Initialize before workers. The OS supplies 96 random bits; the counter is
 * unique within this instance. Cross-instance uniqueness is probabilistic.
 * These values are identifiers, not secrets. Not signal-handler safe. A child
 * must not use the inherited sequence; after a multithreaded fork it must exec
 * before initialization or other non-async-signal-safe operations. Destroy
 * only after all owners and workers are stopped and joined. */
int hc_nonce_sequence_init(HCNonceSequence *);
int hc_nonce_sequence_next(void *,uint8_t[16]);
int hc_nonce_sequence_destroy(HCNonceSequence *);
#endif
