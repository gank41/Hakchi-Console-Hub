#ifndef HC_INTENT_V2_H
#define HC_INTENT_V2_H
#include <stddef.h>
typedef enum {HCIV2_PERIODIC=1,HCIV2_FINAL=2} HCIV2Kind;
typedef struct {char session[96],workspace[44],region[64];HCIV2Kind kind;int workspace_present;} HCIV2Entry;
/* Experimental intent evidence only. Caller authenticates session and region,
 * holds exclusive access to a stable private 0700 parent and its descriptors,
 * and creates the intent durably before creating its checkpoint workspace.
 * Create each workspace before reserving the next intent; capacity checking
 * is not a concurrent reservation.
 * A -2 create result means a record may remain; inspect it, do not retry by
 * replacing it. Checksum is not authentication. Scan accepts structurally
 * valid records only; unknown intent-prefixed names fail closed. It is not
 * proof of prior fsync or authority to restore/delete. */
int hciv2_create(int parent,const char *session,const char *workspace,const char *region,HCIV2Kind kind);
int hciv2_scan(int parent,const char *session,size_t *count);
/* Validated read-only snapshot; no partial output or count change on error.
 * Unknown/malformed checkpoint-prefixed entries also fail closed; an intent
 * may legitimately precede workspace creation; workspace_present is only a
 * type/owner/mode observation, not authentication. Order is unspecified.
 * These are untrusted evidence, not authentication,
 * committed operations, or permission to delete/restore. Exclusive parent
 * access is required for the full call; output and count must not overlap. */
int hciv2_inventory(int parent,const char *session,HCIV2Entry *entries,size_t capacity,size_t *count);
/* For a verified, retired periodic workspace only. Caller holds exclusive
 * parent access and has already verified and durably removed the workspace.
 * -2 means unlink occurred but its durability is uncertain. */
int hciv2_remove_retired(int parent,const char *session,const char *workspace,const char *region);
/* Caller has verified the current save against independently trusted bytes,
 * authenticated this exact session and confirmed the workspace is absent.
 * Only the specified periodic or final record is removed; -2 is an uncertain
 * directory sync after removal. This does not restore or delete save bytes. */
int hciv2_remove_confirmed_orphan(int parent,const char *session,const char *workspace,const char *region,HCIV2Kind kind);
#endif
