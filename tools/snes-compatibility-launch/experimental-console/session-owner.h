#ifndef HC_SESSION_OWNER_H
#define HC_SESSION_OWNER_H
#include "sram-session-prototype.h"
#include "periodic-owner.h"
#include "nonce-sequence.h"
#include "hc-intent-v2.h"
typedef struct {int parent;const char *identity;unsigned type;} HCSessionExpected;
/* Validate exact parent/path associations and reject aliases of one save. */
int hc_session_validate_regions(const HCSessionExpected *,size_t);
/* KEEP_PREVIOUS permits deletion of older verified recovery copies after a
 * newer save; it requires an explicit caller decision. KEEP_ALL preserves all
 * copies but refuses further writes after 16 publications. Both policies leave
 * retained workspaces requiring a future recovery flow on restart. */
typedef enum {HC_RETENTION_KEEP_ALL=1,HC_RETENTION_KEEP_PREVIOUS=2} HCSessionRetention;
typedef struct {void *owner;size_t index;} HCSessionNonceContext;
typedef struct {
 int state,workers_closing;uid_t uid;size_t count;HCSessionRetention retention;int parents[16];unsigned types[16];char paths[16][1024];
 uint8_t session_token[16];uint64_t expected_epoch;
 HCNonceSequence nonces;HCPeriodicOwner *owners[16];HCPeriodicRouter router;
 char journal_session[33];HCSessionNonceContext nonce_contexts[16];
 HCAutosaveTarget finals[16];HCAutosaveTarget *final_ptrs[16];
} HCSessionOwner;
#define HC_SESSION_OWNER_INITIALIZER {0}
/* Caller authenticates the game and paths and controls parent descriptors
 * throughout installation. The owner retains duplicate close-on-exec
 * descriptors; the caller must preserve exclusive directory access and owner
 * lifetime through the session and recovery. Once registered, failures retain
 * objects and files; no cleanup or reset API is provided. Caller supplies a
 * fresh unpredictable session token, authenticated epoch and game identity;
 * the token is correlation evidence, not authentication by itself. */
int hc_session_owner_install(HCSessionOwner *,uid_t,const HCSessionExpected *,size_t,HCSessionRetention,const uint8_t session[16],uint64_t expected_epoch);
/* Main thread, only after all writers are stopped/joined and exclusive parent
 * access is established. Shared parents include all regions. This is read-only
 * evidence; each region must match exactly one expected path in that parent.
 * This only checks the owner's caller-supplied bindings, not their authenticity;
 * it neither authorizes recovery nor proves an operation committed. */
int hc_session_owner_inventory(HCSessionOwner *,size_t,HCIV2Entry *,size_t,size_t *);
/* After an owner exits, a separately authenticated supervisor may reopen the
 * original private parent descriptors and supply the exact session token and
 * game/region bindings it securely retained before launch. No trust is derived
 * from this token or on-disk journal. The caller must prove all writers are
 * stopped and hold exclusive parent access; this check is read-only and does
 * not authorize restoration or deletion. Output is unchanged on failure. */
int hc_session_recovery_inventory(const HCSessionExpected *,size_t,size_t,const uint8_t session[16],HCIV2Entry *,size_t,size_t *);
/* Main-thread only after successful preparation. Stop admission before
 * stopping and joining workers; their leases are released after join. A
 * drained result covers only these registered periodic workers. It does not
 * authorize frontend teardown or recovery. */
int hc_session_owner_begin_worker_shutdown(HCSessionOwner *);
int hc_session_owner_workers_drained(HCSessionOwner *);
/* Experimental frontend bridge to the sole installed owner. No teardown or
 * unregistration exists: failure or uncertainty must preserve that owner. */
int hc_session_frontend_begin_worker_shutdown(void);
int hc_session_frontend_workers_drained(void);
#endif
