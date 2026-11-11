#ifndef HC_FRONTEND_MAIN_ENTRY_H
#define HC_FRONTEND_MAIN_ENTRY_H
#include "frontend-bootstrap.h"
#include "arguments.h"
/* Experimental process-entry bridge. The supervisor must independently own and
 * authenticate its executable, pipe, session, core, directory ancestors and
 * descriptors. Matching command-line bytes do not authenticate a peer. A
 * failure can leave recovery material and must not be retried in-process. */
typedef struct {
 const char *objects_root, *profiles_root;
 int input_fd,rom_fd,startup_fd,exit_fd,confirm_fd;
 unsigned timeout_ms;
 const char *core_root,*core_name,*core_sha256;
 /* Zero disables the check for host fixtures; target frontend requires 207. */
 int save_lock_fd;
} HCFrontendEntryConfig;
/* Verify and retain the caller-controlled advisory lock for the SRAM parent.
 * The caller must authenticate the directory ancestry and exclude nonparticipants. */
int hc_frontend_verify_save_lock(int,const char *,uid_t);
int hc_frontend_entry_prepare(HCFrontendBootstrap *,int *,char **,const HCFrontendEntryConfig *);
/* Process-local request status only. This does not authorize capture. */
int hc_frontend_entry_screenshot_requested(void);
int hc_frontend_entry_savestate_requested(void);
/* Borrowed for the lifetime of the retained bootstrap; not authorization. */
const char *hc_frontend_entry_savestate_path(void);
/* Read the saved manager paths for the bootstrap's exact session. Caller
 * authenticates the console and hierarchy and keeps all writers stopped. */
int hc_frontend_entry_observe_manager(const HCFrontendBootstrap *,const HCFrontendEntryConfig *,HCManagerCheckpointPaths *);
/* Includes the time paths; both outputs remain unchanged on failure. This is
 * correlation data only and does not authorize reading or writing the paths. */
int hc_frontend_entry_observe_manager_full(const HCFrontendBootstrap *,const HCFrontendEntryConfig *,HCManagerCheckpointPaths *,HCManagerTimePaths *);
/* Recheck immediately before entering the frontend; the trusted supervisor
 * must prevent concurrent changes until the dynamic loader has consumed it. */
int hc_frontend_entry_core_ready(void);
/* Produces a procfs path to the retained verified descriptor, never a newly
 * opened pathname. Caller keeps exclusive control of the file while loading. */
int hc_frontend_entry_core_load_path(const char *,char *,size_t);
#endif
