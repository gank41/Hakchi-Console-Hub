#ifndef HC_RECOVERY_OBSERVER_H
#define HC_RECOVERY_OBSERVER_H
#include "recovery-binding.h"
#include <stdint.h>
#include <sys/types.h>
/* Read-only evidence from caller-owned, independently trusted open directories.
 * The caller must exclude writers and authenticate the expected game, session,
 * path and directory ancestry; this API does not authorize recovery. On
 * failure output is unchanged. */
typedef struct { uint64_t device, inode; size_t descriptor_length, entry_count; char descriptor[20000]; HCIV2Entry entries[16]; } HCRecoveryObservation;
int hc_recovery_observe(int,const char *,const char *,const char *,const uint8_t[16],uint64_t,const HCSessionExpected *,size_t,size_t,HCRecoveryObservation *);
/* Read-only staged PNG candidate, never completion or recovery authority. The
 * caller independently authenticates game/session/paths, stops all writers and
 * holds exclusive access through the call. Buffer and length must not overlap
 * each other or any input. On failure both outputs remain unchanged. */
int hc_recovery_read_staged_png(int,const char *,const char *,const char *,const uint8_t[16],uint64_t,const HCSessionExpected *,size_t,size_t,const char *,void *,size_t,size_t *);
/* Read a published retained PNG correlated to a pending final image intent.
 * Caller authenticates the binding and paths, excludes writers and holds all
 * directories. This is evidence only, not completion or restore authority.
 * Buffer and length must not overlap; both remain unchanged on failure. */
int hc_recovery_read_retained_png(int,const char *,const char *,const char *,const uint8_t[16],uint64_t,const HCSessionExpected *,size_t,size_t,void *,size_t,size_t *);
/* Collect the correlated binding and retained bytes together. Caller excludes
 * writers and authenticates inputs; outputs must not overlap and remain
 * unchanged on failure. This is not permission to restore or delete. */
int hc_recovery_collect_retained_png(int,const char *,const char *,const char *,const uint8_t[16],uint64_t,const HCSessionExpected *,size_t,size_t,HCRecoveryObservation *,void *,size_t,size_t *);
/* Session-named retained image. Caller must independently authenticate paths,
 * game and session, exclude writers and hold exclusive access. Collection is
 * read-only evidence, not proof of completion or authority to restore. */
int hc_recovery_collect_session_retained(int,const char *,const char *,const uint8_t[16],uint64_t,const HCSessionExpected *,size_t,size_t,HCRecoveryObservation *,void *,size_t,size_t *);
/* Completed-image evidence after the final journal was retired. The caller
 * independently authenticates the session and expected image digest and
 * excludes writers. A matching binding alone does not prove image identity. */
int hc_recovery_collect_session_retired_image(int,const char *,const char *,const uint8_t[16],uint64_t,const HCSessionExpected *,size_t,size_t,HCRecoveryObservation *,void *,size_t,size_t *);
/* Read-only session-named retained state; caller authenticates session and
 * exclusive directory ownership. Outputs remain unchanged on failure. */
int hc_recovery_collect_session_retained_state(int,const char *,const char *,const uint8_t[16],uint64_t,const HCSessionExpected *,size_t,size_t,HCRecoveryObservation *,void *,size_t,size_t *);
/* Open an existing game save hierarchy without creating anything. The caller
 * supplies a pinned, independently authenticated profiles root and excludes
 * writers; matching is correlation, not recovery authorization. */
#include "launch-request.h"
int hc_recovery_observe_game(int,const char *,uid_t,const HCLaunchRequest *,size_t,HCRecoveryObservation *);
/* A cooperative, nonblocking lock on the observed game/ROM save directory.
 * Caller still authenticates the console and excludes nonparticipating writers. */
int hc_recovery_lock_game(int,uid_t,const HCLaunchRequest *,uint64_t,uint64_t);
/* Correlate a retained state with the specified game and session using the
 * existing persistent hierarchy. paired must reflect the independently
 * selected manager record. Caller authenticates the console and excludes all
 * writers and path mutation. Results are evidence, not restore authority. */
int hc_recovery_collect_game_state(int,const char *,uid_t,const HCLaunchRequest *,int,HCRecoveryObservation *,void *,size_t,size_t *);
/* Read-only captured-state evidence from the exact session's private archive.
 * Caller authenticates the console and session and excludes writers; bytes
 * require an independent trusted comparison before any recovery action. */
int hc_recovery_collect_game_state_archive(int,const char *,uid_t,const HCLaunchRequest *,HCRecoveryObservation *,void *,size_t,size_t *);
/* The equivalent read-only retained-image lookup; paired indicates that the
 * independently selected manager record also requested a state. */
int hc_recovery_collect_game_image(int,const char *,uid_t,const HCLaunchRequest *,int,HCRecoveryObservation *,void *,size_t,size_t *);
/* Completed image evidence, with no active journal. The caller must compare
 * the bytes to an independently trusted digest before using them. */
int hc_recovery_collect_game_retired_image(int,const char *,uid_t,const HCLaunchRequest *,int,HCRecoveryObservation *,void *,size_t,size_t *);
/* Read-only exact-session prior-time evidence from the persistent workspace.
 * Caller independently authenticates console, roots and request, and excludes
 * writers. Evidence does not authorize restoration or deletion. */
int hc_recovery_collect_game_time_seed(int,const char *,uid_t,const HCLaunchRequest *,HCRecoveryObservation *,void *,size_t,size_t *);
/* Experimental offline recovery: caller authenticates the request, original
 * evidence and (for absence) the current bytes, stops all writers including
 * descendants, and holds exclusive access. Never authorizes itself. A -2
 * result means a partial filesystem change may have occurred. */
typedef enum { HC_RECOVERY_ORIGINAL_PRESENT=1, HC_RECOVERY_ORIGINAL_ABSENT=2 } HCRecoveryOriginal;
int hc_recovery_restore_game(int,const char *,uid_t,const HCLaunchRequest *,size_t,const char *,HCRecoveryOriginal,const void *,size_t);
/* Bounded, read-only live bytes. Caller authenticates the session/root and
 * excludes all writers; observation alone never authorizes restoration. */
typedef struct { uint64_t device, inode; int present; size_t length; unsigned char bytes[128 * 1024]; } HCRecoveryLiveSave;
int hc_recovery_read_current_game(int,const char *,uid_t,const HCLaunchRequest *,size_t,HCRecoveryLiveSave *);
#endif
