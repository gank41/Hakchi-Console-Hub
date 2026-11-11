#ifndef HC_CONSOLE_SUPERVISOR_H
#define HC_CONSOLE_SUPERVISOR_H
#include "verified-launch.h"
#include "child_process.h"
#include "arguments.h"
#include <stddef.h>
/* Single-threaded prototype. The caller authenticates the executable, game,
 * expected ROM digest and channel peers, and retains exclusive control of all
 * files and descriptors. Both startup and confirmation observations remain
 * provisional; neither authorizes a game, restore, deletion, or termination.
 * Startup and confirmation pipes are created and owned by this supervisor.
 * A failed start can leave an owned child quarantined; inspect phase before retry.
 * This module does not yet implement a child release or safe shutdown protocol. */
enum {HC_SUPERVISOR_EMPTY,HC_SUPERVISOR_CHILD_STARTED,HC_SUPERVISOR_STARTUP_OBSERVED,HC_SUPERVISOR_CONFIRMATION_OBSERVED,HC_SUPERVISOR_QUARANTINED,HC_SUPERVISOR_REAPED,HC_SUPERVISOR_RELEASED_FOR_TEST,HC_SUPERVISOR_QUIT_SENT_FOR_TEST};
enum {HC_START_STAGE_NONE,HC_START_STAGE_INITIAL,HC_START_STAGE_CONFIRMATION};
enum {HC_START_FAILURE_NONE,HC_START_FAILURE_REPORTED,HC_START_FAILURE_PROTOCOL,HC_START_FAILURE_TIMEOUT,HC_START_FAILURE_TRANSPORT};
/* Failure classification is observational and grants no recovery authority. */
typedef struct {int phase;HCChild child;HCVerifiedLaunch rom;uint8_t session[16];uint64_t epoch;char game[12];int recovery_required;int startup_reader;int confirmation_reader;int startup_pin;int confirmation_pin;int launch_sent;char sram_path[HC_ARGUMENT_BYTES],rtc_path[HC_ARGUMENT_BYTES];int startup_failure_stage,startup_failure_kind;} HCConsoleSupervisor;
#define HC_CONSOLE_SUPERVISOR_INITIALIZER {0,HC_CHILD_INITIALIZER,HC_VERIFIED_LAUNCH_INITIALIZER,{0},0,{0},0,-1,-1,-1,-1,0,{0},{0},0,0}
/* Reviewed startup only. The caller independently authenticates the program,
 * request, game, ROM, output descriptors and environment; supplies the
 * already verified ROM and keeps it open while startup copies its descriptors;
 * controls every path and fd; validates the manager and eventfd ownership; and remains the sole child supervisor. argv must start with a literal
 * -s and the game/ROM/emulator-specific SRAM path, and contain no competing save option or
 * option terminator. This
 * rechecks and retains the reviewed ROM; it does not authenticate the frontend or
 * create, authenticate or pin its parent directory, establish save-file
 * format, or ensure its session owner actually uses that path. A failed start can leave
 * a live quarantined child or recovery evidence; inspect the resulting phase.
 * Success observes reports only, never releases gameplay or authorizes writes. */
typedef struct {
 int directory;const char *rom_name;uid_t uid;const char *game,*digest;
 /* Optional trusted absolute roots; NULL selects the console defaults. */
 const char *objects_root,*profiles_root;
 HCVerifiedLaunch *verified_rom;
 /* Required by the runtime: caller supplies independently verified executable. */
 HCVerifiedLaunch *verified_frontend;
 int manager_argc;const char *const *manager_argv;const char *expected_sram,*expected_rtc;
 uint8_t session[16];uint64_t epoch;const char *program;char *const *argv,*const *envp;
 int report_fd,report_target,save_fd,save_target,image_fd,image_target;
 int startup_target,exit_fd,exit_target,rom_target,confirm_target;
 /* Optional cooperating save lock. A nonzero descriptor requests handoff;
  * callers still authenticate ancestry and exclude nonparticipating writers. */
 int save_lock_fd,save_lock_target;
} HCConsoleStartSpec;
int hc_console_supervisor_start_reviewed(HCConsoleSupervisor *,const HCConsoleStartSpec *,const unsigned char *,size_t,unsigned);
/* Construct the exact frontend-entry argument format from the reviewed frame.
 * The caller must authenticate and exclusively control the executable, core,
 * object root and channels; this function does not authorize game release. */
int hc_console_supervisor_start_frontend(HCConsoleSupervisor *,const HCConsoleStartSpec *,const unsigned char *,size_t,unsigned,const char *core_path);
int hc_console_supervisor_start_owned(HCConsoleSupervisor *,int,const char *,uid_t,const char *,const char *,const uint8_t[16],uint64_t,const char *,char *const [],char *const [],int,int,int,int,int,int,int,int,int,int,int);
int hc_console_supervisor_observe_startup(HCConsoleSupervisor *,int,unsigned);
/* Compare an independently supplied app review to the retained launch; this
 * does not establish who supplied it or authorize the game to run. */
int hc_console_supervisor_send_reviewed_frame(HCConsoleSupervisor *,const unsigned char *,size_t);
int hc_console_supervisor_observe_confirmation(HCConsoleSupervisor *,int,unsigned);
#ifdef HC_TEST_RELEASE_ONLY
/* Host-test-only; real game release remains disabled until shutdown is safe. */
int hc_console_supervisor_release_game_for_test(HCConsoleSupervisor *);
/* Host-only delivery; it does not establish checkpoint success, worker
 * quiescence or safe termination. The trusted caller protects the pipe. */
int hc_console_supervisor_request_quit_for_test(HCConsoleSupervisor *);
#endif
/* Only after the owned child is reaped: restore independently verified
 * previous bytes for exactly this session and its retained save paths. The
 * caller must authenticate the binding, stop every writer (including child
 * descendants), and hold exclusive access. A reaped child alone does not
 * establish that all writers have stopped. Successful restoration does not resolve other pending recovery or authorize cleanup. */
int hc_console_supervisor_restore_previous(HCConsoleSupervisor *,int,const char *,const HCSessionExpected *,size_t,size_t,const char *,const void *,size_t);
/* Read-only evidence and an independently stopped, exclusive session remain
 * caller prerequisites; this retains the current save and restores absence. */
int hc_console_supervisor_restore_absent(HCConsoleSupervisor *,int,const char *,const HCSessionExpected *,size_t,size_t,const char *,const void *,size_t);
int hc_console_supervisor_poll(HCConsoleSupervisor *,int *);
/* Close only a reaped quarantined child's input; preserve the quarantine and
 * recovery requirement. Caller excludes concurrent FD-table reuse. */
int hc_console_supervisor_close_quarantined_input(HCConsoleSupervisor *);
/* Promote quarantine to reaped only when waitpid actually returned the owned
 * child and input cleanup completed. ECHILD and live/unknown children remain
 * quarantined. Recovery remains required, and this does not establish that
 * descendants or other save writers have stopped. */
int hc_console_supervisor_confirm_reaped(HCConsoleSupervisor *, int *);
/* Requires exclusive descriptor-table ownership and no child input. Failed
 * closes retain still-open channels and the verified ROM for retry. */
int hc_console_supervisor_release(HCConsoleSupervisor *);
#endif
