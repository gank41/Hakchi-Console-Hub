#ifndef HC_RECOVERY_BINDING_H
#define HC_RECOVERY_BINDING_H
#include "session-owner.h"
/* Experimental supervisor seam. The caller authenticates game, ROM, token,
 * epoch, region paths and this trusted private directory independently, before
 * creation and again at recovery. It must ensure exclusive access and stop all
 * writers before inventory. The record is not cryptographic authentication;
 * neither it nor a successful inventory authorizes restore or deletion.
 * Create before launch and launch only on success. Any failed create may leave
 * a record: preserve it and do not retry using the same name. A power loss has
 * not been tested. File system durability requires working file and directory
 * fsync. Inputs must provide valid readable memory and output/count must not
 * overlap each other or any input. Output and count remain unchanged on
 * inventory failure. Descriptor names must avoid journal-reserved prefixes. */
int hc_binding_create(int trusted_dir,const char *name,const char *game,const char *rom,const uint8_t session[16],uint64_t epoch,const HCSessionExpected *regions,size_t count);
int hc_binding_inventory(int trusted_dir,const char *name,const char *game,const char *rom,const uint8_t session[16],uint64_t epoch,const HCSessionExpected *regions,size_t count,size_t index,HCIV2Entry *entries,size_t capacity,size_t *out_count);
/* After a supervisor has independently authenticated the complete binding,
 * stopped all writers and obtained exclusive access, retire one orphaned
 * periodic or final intent only if the current save matches independently trusted
 * bytes. Does not restore a save or authorize other cleanup. -2 means the
 * intent may have been removed but directory sync failed. */
int hc_binding_retire_orphan(int trusted_dir,const char *binding,const char *game,const char *rom,const uint8_t session[16],uint64_t epoch,const HCSessionExpected *regions,size_t count,size_t index,const char *workspace,const void *expected,size_t length);
/* Recover one verified previous save after all writers have stopped and the
 * caller has authenticated this exact binding and holds exclusive access.
 * The previous bytes must match independently trusted data. Existing current
 * bytes are preserved in the workspace; no evidence is deleted. Zero means
 * restored or already restored, -1 means refusal before a rename, and -2
 * means a rename may have occurred but durability could not be confirmed. */
int hc_binding_restore_previous(int,const char *,const char *,const char *,const uint8_t[16],uint64_t,const HCSessionExpected *,size_t,size_t,const char *,const void *,size_t);

/* Complete a verified final publication after all writers have stopped and an
 * independently retained backup exists. The caller authenticates the binding,
 * paths and both byte snapshots and holds exclusive access. A -2 result means
 * cleanup may have partially happened; retain the intent and reconcile it.
 * A missing previous file in an otherwise empty workspace is accepted on retry.
 * NULL/0 for previous requires independently verified original absence and
 * refuses an unexpected previous file. */
int hc_binding_finish_published(int,const char *,const char *,const char *,const uint8_t[16],uint64_t,const HCSessionExpected *,size_t,size_t,const char *,const void *,size_t,const void *,size_t);
/* Retire an authenticated, unpublished final intent only after all writers
 * have stopped. expected/length describe independently verified unchanged
 * target bytes; NULL/0 requires that the target is absent. Only the empty
 * save.tmp and its private workspace may be removed. A -2 result means the
 * cleanup may be partial and must be reconciled; the binding is retained. */
int hc_binding_finish_unpublished(int,const char *,const char *,const char *,const uint8_t[16],uint64_t,const HCSessionExpected *,size_t,size_t,const char *,const void *,size_t);
/* Restore an independently verified originally absent region by retaining
 * the independently verified current bytes in the matching workspace, then
 * removing only the live name. Caller authenticates original absence, current
 * bytes and session, stops all writers and holds exclusive access. On success
 * the retained copy remains; -2 means a filesystem change may have occurred. */
int hc_binding_restore_absent(int,const char *,const char *,const char *,const uint8_t[16],uint64_t,const HCSessionExpected *,size_t,size_t,const char *,const void *,size_t);

#endif
