#ifndef HC_PERIODIC_OWNER_H
#define HC_PERIODIC_OWNER_H
#include <pthread.h>
#include <stdint.h>
#include "autosave_target.h"
typedef int (*HCNonceSource)(void *,uint8_t[16]);
typedef int (*HCRetiredIntentCleanup)(void *,const char *);
typedef struct {
 pthread_mutex_t lock;int active,parent,failed,routed;uid_t owner;size_t count;
 char identity[1024],destination[128];HCNonceSource nonce;void *nonce_context;HCRetiredIntentCleanup retire_intent;void *retire_context;
 HCAutosaveTarget targets[16];uint8_t attempted_nonces[16][16];int outcomes[16];
 uint64_t previous_device[16],previous_inode[16];int previous_present[16];
 uint64_t previous_size[16];uint8_t previous_digest[16][32];
 uint64_t written_size[16];uint8_t written_digest[16][32];
} HCPeriodicOwner;
#define HC_PERIODIC_OWNER_INITIALIZER {0}
/* Read-only, bounded scan under an exclusively controlled private parent.
 * Counts checkpoint- and intent-prefixed entries, including malformed entries and
 * symlinks; these are not authenticated or safe to remove. Output is changed
 * only on success. A positive count requires a separate recovery decision. */
int hc_periodic_recovery_status(int parent,uid_t owner,size_t *count);
/* Main thread supplies authenticated game/path, private held directory, a
 * cryptographically secure non-repeating nonce source and exclusive access.
 * A nonce source shared by owners must itself be thread-safe and unique across
 * owners and earlier sessions. It runs under router and owner locks: it must
 * not re-enter either object or acquire locks in the reverse order, and must
 * complete promptly. One worker may publish to each identity.
 * Owner and descriptors remain alive through all worker joins and recovery.
 * All owners sharing a parent must initialize before any of them publishes.
 * Init refuses any retained checkpoint entry, including normal successful
 * snapshots, until a future authenticated recovery flow resolves them. */
int hc_periodic_owner_init(HCPeriodicOwner *,int,uid_t,const char *,const char *,HCNonceSource,void *);
/* Serialized callback, usable only under the owner preconditions. Direct
 * calls are refused once the owner belongs to a router. Workspaces are
 * retained; errors block further publication for explicit inspection. */
int hc_periodic_owner_publish(void *,const char *,const void *,size_t);
/* Set during single-threaded setup before router binding or publication. */
int hc_periodic_owner_set_retired_intent_cleanup(HCPeriodicOwner *,HCRetiredIntentCleanup,void *);
/* Experimental: retire the oldest successfully superseded workspace after
 * verifying the current destination. The caller must retain exclusive
 * directory access and all publishers must use this owner. Never call on an
 * uncertain operation. This does not establish a Mac backup or a session. */
typedef struct {pthread_mutex_t lock;HCPeriodicOwner *owners[16];unsigned workers[16];size_t count;int ready,failed,auto_reclaim,started,closing_workers;} HCPeriodicRouter;
#define HC_PERIODIC_ROUTER_INITIALIZER {0}
/* Main thread builds once before workers start; owners and router remain
 * immutable and alive through every worker join. Duplicate paths are refused. */
int hc_periodic_router_init(HCPeriodicRouter *,HCPeriodicOwner *const *,size_t);
/* Set once during single-threaded setup, before binding or starting workers. */
int hc_periodic_router_enable_reclaim(HCPeriodicRouter *);
int hc_periodic_router_publish(void *,const char *,const void *,size_t);
int hc_periodic_router_reclaim_oldest(HCPeriodicRouter *,const char *);
/* Trusted session owner only: acquire before starting a worker and release
 * after it has joined, or if creation failed. These are not capabilities;
 * they do not authenticate the caller or establish a shutdown barrier. */
int hc_periodic_router_worker_acquire(void *,const char *);
int hc_periodic_router_worker_release(void *,const char *);
/* Main-thread supervisor closes admission before joining all workers. Workers
 * already leased may finish publishing until their joins release the leases.
 * Drained is only a point-in-time lease count, not proof that other task
 * producers, callbacks, core access or unregistered threads have stopped.
 * All calls and router/owner lifetimes require the existing trusted-caller and
 * exclusive-ownership contracts; the flag never reopens in this session. */
/* Nonblocking: a busy router returns -1 (close) or 0 (drained). The caller
 * must retry and must not infer that admission closed or workers stopped. */
int hc_periodic_router_close_workers(HCPeriodicRouter *);
int hc_periodic_router_workers_drained(HCPeriodicRouter *);
/* Called during single-threaded worker preflight, before publications start. */
_Bool hc_periodic_router_can_publish(void *,const char *);
#endif
