#ifndef HC_CONSOLE_RUNTIME_H
#define HC_CONSOLE_RUNTIME_H
#include "launch-request.h"
#include "console-supervisor.h"
#include <sys/types.h>
/* The caller authenticates game and digest and exclusively controls the private
 * parent, the workspace, executable path and descriptors. The caller supplies
 * the independently reviewed frontend digest; checks do not authorize gameplay. Failed preparation can leave a workspace;
 * retain it for inspection. Close only after every child/writer has stopped. */
typedef struct {
 HCLaunchRequest request;
 HCVerifiedLaunch frontend;
 int workspace,save,image,report[2],exitpipe[2],attempted,exit_pin,exit_observed,claimed,stock_claimed,save_lock;
 HCConsoleSupervisor *supervisor;
 char workspace_name[44];
} HCConsoleRuntime;
#define HC_CONSOLE_RUNTIME_INITIALIZER {{0},HC_VERIFIED_LAUNCH_INITIALIZER,-1,-1,-1,{-1,-1},{-1,-1},0,-1,0,0,0,-1,NULL,{0}}
/* Open the fixed sessions child of a pinned private game/ROM save directory.
 * create=1 may create only that child; create=0 is read-only. Caller must
 * authenticate the parent and exclude concurrent path changes. */
int hc_console_runtime_open_session_parent(int,uid_t,int);
int hc_console_runtime_prepare(HCConsoleRuntime *,int,uid_t,const char *,const char *);
/* Prepare the selected game's persistent workspace and retain its save lock.
 * The caller authenticates the reviewed inputs and excludes other writers.
 * A failure may leave a directory or workspace; close the runtime and inspect
 * retained files. This does not start the frontend or authorize gameplay. */
int hc_console_runtime_prepare_game(HCConsoleRuntime *,const HCConsoleStartSpec *);
/* Use a caller-authenticated, independently reviewed request. Session and
 * epoch are preserved exactly; an existing workspace is never reused. This
 * does not authenticate the caller or authorize a console launch. The caller
 * must supply an unpredictable, never-reused session and a trusted parent;
 * workspace exclusivity alone cannot prevent replay after its removal. */
int hc_console_runtime_prepare_bound(HCConsoleRuntime *,int,uid_t,const HCLaunchRequest *,const char *,const char *);
/* Discard only an empty workspace never handed to a session or frontend.
 * Caller owns the private parent and excludes any other references/writers.
 * -2 means a partial deletion or durability failure; preserve for inspection. */
int hc_console_runtime_discard_unstarted(HCConsoleRuntime *,int,HCConsoleSupervisor *);
/* One startup attempt per workspace. If no lock is supplied, acquire the
 * reviewed SRAM directory lock, creating isolated subfolders if needed, and
 * retain it until runtime close.
 * The child inherits a duplicate. This does not exclude uncooperative writers
 * or authenticate ancestry. On failure inspect the supervisor phase; a live
 * or quarantined child must remain owned and supervised. */
int hc_console_runtime_start(HCConsoleRuntime *,HCConsoleSupervisor *,const HCConsoleStartSpec *,unsigned,const char *);
/* Parse the actual menu command and derive game-specific save identities;
 * all executable, roots, descriptors and manager peers remain caller-trusted. */
int hc_console_runtime_start_command(HCConsoleRuntime *,HCConsoleSupervisor *,int,const char *const [],const HCConsoleStartSpec *,unsigned,const char *);
/* Wait for an expected exit-failure report. Success only confirms the
 * failure frame; either result quarantines the session and requires recovery.
 * Caller owns the child and excludes all other pipe readers and waiters. */
int hc_console_runtime_observe_exit_failure(HCConsoleRuntime *,HCConsoleSupervisor *,unsigned);
/* Retry a quarantined input close and consume only an actual waitpid status
 * from this runtime's supervisor. Returns 1 when reaped, 0 when status is
 * unknown, or -1 on error. Recovery remains required; other writers must be
 * independently stopped before any restoration. Caller excludes concurrent
 * descriptor-table use and child waiters. */
int hc_console_runtime_resolve_reaped(HCConsoleRuntime *,HCConsoleSupervisor *,int *);
/* The caller excludes concurrent descriptor creation, close, or reuse.
 * A failed close retains a still-open descriptor and later resources, including
 * the save lock; retry cleanup only under the same exclusive ownership. */
int hc_console_runtime_close(HCConsoleRuntime *,HCConsoleSupervisor *);
#endif
