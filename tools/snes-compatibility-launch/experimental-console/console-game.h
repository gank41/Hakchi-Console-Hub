#ifndef HC_CONSOLE_GAME_H
#define HC_CONSOLE_GAME_H
#include "arguments.h"
#include "verified-launch.h"
#include "console-runtime.h"
/* Parse the exact menu command and retain the verified named ROM. Caller
 * authenticates the object directory, game metadata and expected digest, and
 * prevents concurrent file changes until all users of the ROM are stopped. */
typedef struct {HCCompatibilityMenuCommand command;HCVerifiedLaunch rom;} HCConsoleGame;
#define HC_CONSOLE_GAME_INITIALIZER {{0},HC_VERIFIED_LAUNCH_INITIALIZER}
/* Returns -2 for an invalid command and -1 for a verification failure. */
int hc_console_game_open(HCConsoleGame *,int,const char *const [],int,uid_t);
/* Retain the prepared ROM through the supervisor's actual startup attempt.
 * The caller authenticates the executable, peer, roots and session resources. */
int hc_console_game_start(HCConsoleGame *,HCConsoleRuntime *,HCConsoleSupervisor *,int,const char *const [],const HCConsoleStartSpec *,unsigned,const char *);
/* Record the checked manager paths before a frontend starts. Does not start
 * gameplay; existing records are never overwritten. */
int hc_console_game_prepare_manager_record(HCConsoleGame *,HCConsoleRuntime *,int,const char *const []);
/* Compare a private, durable manager-path record with independently reviewed
 * expectations. This is correlation only and does not authorize recovery. */
int hc_console_game_check_manager_record(int,const HCLaunchRequest *,const HCManagerCheckpointPaths *);
#define HC_MANAGER_RECORD_MAX (125+5*(HC_ARGUMENT_BYTES-1))
/* Full records additionally preserve manager play-time paths. Existing
 * checkpoint-only readers refuse them rather than silently drop fields. */
int hc_console_game_check_manager_record_full(int,const HCLaunchRequest *,const HCManagerCheckpointPaths *,const HCManagerTimePaths *);
/* Read correlation data from a pinned private workspace. The caller selects
 * and authenticates the game and ROM, pins directory ancestry, and excludes
 * writers. Output is unchanged on failure; a match authorizes no action. */
int hc_console_game_observe_manager_record(int,const char *,const char *,HCLaunchRequest *,HCManagerCheckpointPaths *);
int hc_console_game_observe_manager_record_full(int,const char *,const char *,HCLaunchRequest *,HCManagerCheckpointPaths *,HCManagerTimePaths *);
/* Export the same canonical observation for a bounded read-only transport.
 * The destination and length must not overlap; failure leaves both intact. */
int hc_console_game_export_manager_record(int,const char *,const char *,void *,size_t,size_t *);
/* Observe the exact session's saved manager paths under a pinned profiles
 * root. Caller authenticates the root and request and excludes writers. */
int hc_console_game_read_session_manager(int,const char *,uid_t,const HCLaunchRequest *,HCManagerCheckpointPaths *);
/* Includes time paths when present. Both outputs are unchanged on failure;
 * the observations still require independent authentication before use. */
int hc_console_game_read_session_manager_full(int,const char *,uid_t,const HCLaunchRequest *,HCManagerCheckpointPaths *,HCManagerTimePaths *);
enum {HC_MANAGER_RECORD_PRESENT=1,HC_MANAGER_RECORD_INCOMPLETE=2};
typedef struct {char workspace[44];int status;HCLaunchRequest request;HCManagerCheckpointPaths paths;HCManagerTimePaths time;} HCManagerRecordObservation;
/* Locate an existing session parent beneath a pinned, authenticated profiles
 * root. Returns -2 only for a verified absent sessions child, -1 for other
 * errors. No files are created. Caller excludes concurrent path changes. */
int hc_console_game_open_persistent_sessions(int,const char *,uid_t,const char *,const char *);
/* Enumerate private session workspaces under the caller-pinned parent. Records
 * are observations, not authority; caller excludes writers. Up to 1024 results;
 * an absent record is reported incomplete; malformed records cause refusal. Outputs remain unchanged
 * on failure. The result and count must not overlap any inputs. */
int hc_console_game_inventory_manager_records(int,const char *,const char *,HCManagerRecordObservation *,size_t,size_t *);
#define HC_MANAGER_INVENTORY_MAX 1024u
/* Check existing private session metadata without the inventory's output
 * limit. Missing or invalid metadata causes refusal; a valid record
 * does not establish that its session completed or that recovery is clear.
 * No files change. Caller holds the game lock and excludes writers. */
int hc_console_game_check_manager_record_inventory(int,const char *,const char *);
/* Retains the command and ROM on a failed close so cleanup can be retried.
 * The caller excludes descriptor reuse during close and retry. */
int hc_console_game_close(HCConsoleGame *);
#endif
