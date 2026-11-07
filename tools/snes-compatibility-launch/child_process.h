#ifndef HAKCHI_SNES_CHILD_PROCESS_H
#define HAKCHI_SNES_CHILD_PROCESS_H
#include <sys/types.h>
typedef struct { pid_t pid; int input; int reaped_pending; int reaped_status; } HCChild;
#define HC_CHILD_INITIALIZER { -1, -1, 0, 0 }
/* Caller must verify executable, arguments and environment, and arrange all
 * unrelated inherited descriptors close-on-exec. Caller must be sole child
 * reaper and retain exclusive ownership until reaped, to prevent PID reuse;
 * SIGCHLD may not be ignored, auto-reaped, or changed during the child lifetime;
 * a custom SIGCHLD handler must not reap or alter this child;
 * no other thread may close or replace descriptors. Single-threaded setup only.
 * The child inherits the spawning thread's signal mask; a blocked SIGTERM may
 * prevent graceful termination. The caller must establish and preserve an
 * appropriate mask and must not assume a successful signal means child exit.
 * No executable authenticity, game identity, save, transition, or launch gate
 * is established here. Input commands and bounded deadlines are caller duties. */
int hc_child_start(HCChild *child, const char *program, char *const argv[], char *const envp[]);
/* Pass a caller-verified, read-only ROM descriptor to a fixed child number.
 * Caller authenticates executable, ROM and arguments, prevents mutation, and
 * ensures the child consumes that descriptor. A pathname is not proof. */
int hc_child_start_rom(HCChild *,const char *,char *const [],char *const [],int,int);
/* Adds an exclusive report pipe to a currently unused child descriptor.
 * Caller owns report_fd and must close its own copy after successful spawn. */
int hc_child_start_reporting(HCChild *child,const char *program,char *const argv[],char *const envp[],int report_fd,int child_report_fd);
/* Pass one pinned ROM and a separate private nonblocking report pipe. The
 * caller authenticates child, ROM and message, and owns the report reader. */
int hc_child_start_rom_reporting(HCChild *,const char *,char *const [],char *const [],int,int,int,int);
/* A cooperating child retains the caller's locked save-directory descriptor
 * across exec. This does not constrain nonparticipating writers. */
int hc_child_start_rom_reporting_lock(HCChild *,const char *,char *const [],char *const [],int,int,int,int,int,int);
/* One ROM, save report, isolated-save lock and distinct screenshot receipt.
 * Caller authenticates the frontend and session and retains the read ends. */
int hc_child_start_rom_reporting_lock_receipt(HCChild *,const char *,char *const [],char *const [],int,int,int,int,int,int,int,int);
int hc_child_start_rom_lock(HCChild *,const char *,char *const [],char *const [],int,int,int,int);
/* Additionally passes two distinct private, empty owned files. The caller
 * protects descriptor and path identity, verifies the workspace and retains
 * exclusive ownership until the child has stopped. Target descriptors must be
 * unused and distinct from every source and each other. SIGPIPE must be
 * ignored before spawning and remain ignored in the parent and child. Parent
 * and child share open-file descriptions; do not change offsets or status
 * flags while the child owns these files. */
int hc_child_start_checkpoint(HCChild *child,const char *program,char *const argv[],char *const envp[],int report_fd,int report_target,int save_fd,int save_target,int image_fd,int image_target);
/* Adds distinct dedicated startup and exit report pipes to the checkpoint
 * spawn. Caller authenticates the executable, session and game, keeps exclusive
 * ownership, closes its writer copies after spawn, supervises the unreaped
 * child and treats missing reports as uncertain. This alone does not launch a
 * safe session or authorize recovery. */
int hc_child_start_supervised(HCChild *child,const char *program,char *const argv[],char *const envp[],int report_fd,int report_target,int save_fd,int save_target,int image_fd,int image_target,int startup_fd,int startup_target,int exit_fd,int exit_target);
/* Also passes a read-only ROM descriptor. Caller must independently verify its
 * game identity and contents, ensure the child consumes this exact descriptor,
 * and retain exclusive access to the file through use. Descriptor validation
 * here is not authenticity or permission to start the emulator. */
int hc_child_start_verified(HCChild *,const char *,char *const [],char *const [],int,int,int,int,int,int,int,int,int,int,int,int);
/* Passes a fourth distinct report pipe for the child's later confirmation.
 * This does not itself authenticate or authorize startup. */
int hc_child_start_confirmed(HCChild *,const char *,char *const [],char *const [],int,int,int,int,int,int,int,int,int,int,int,int,int,int);
int hc_child_start_confirmed_lock(HCChild *,const char *,char *const [],char *const [],int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int);
/* Caller excludes descriptor creation, close and reuse by other threads and
 * signal handlers during poll and cleanup. Failed closes retain a descriptor
 * if still open; callers must quarantine it and retry cleanup only after the
 * child is reaped. A failed poll never supplies usable completion evidence. */
int hc_child_close_input(HCChild *child);
/* After a failed input close, retrieve an actually reaped status only after
 * input cleanup. ECHILD does not establish status. Consumes evidence once;
 * caller retains exclusive child/descriptor ownership throughout. */
int hc_child_take_reaped(HCChild *child, int *status);
/* Return 1 after reaping and closing input, 0 while still pending (including
 * interrupted waits), -1 on error. No status is supplied while pending. */
int hc_child_poll(HCChild *child, int *status);
/* Signal only a live owned child; only SIGTERM and SIGKILL are permitted. */
int hc_child_signal(HCChild *child, int signal_number);
#endif
