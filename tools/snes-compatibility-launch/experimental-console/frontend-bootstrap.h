#ifndef HC_FRONTEND_BOOTSTRAP_H
#define HC_FRONTEND_BOOTSTRAP_H
#include "verified-launch.h"
#include "launch-request.h"
#include "arguments.h"
#include <stdbool.h>
/* Single-use prototype. Caller must authenticate the supervisor, executable,
 * game, digest, session and descriptor peers and retain exclusive ownership.
 * A failure may leave an owner, binding, or attached ROM; keep them for review.
 * Success configures startup reporting, but never authorizes game execution. */
typedef struct {int attempted,ready;HCVerifiedLaunch launch;HCSessionOwner owner;
 /* A pinned supervisor input is retained through the one-shot session. Its
  * presence does not authorize gameplay or establish peer authenticity. */
 HCLaunchRequest release_request;int release_input,release_available,release_attempted;
 /* Manager paths are correlation data, not authorization to write. */
 HCManagerCheckpointPaths manager_paths;int manager_paths_ready;
} HCFrontendBootstrap;
#define HC_FRONTEND_BOOTSTRAP_INITIALIZER {0}
int hc_frontend_bootstrap(HCFrontendBootstrap *,int,const char *,int,uid_t,const char *,const char *,const HCSessionExpected *,size_t,HCSessionRetention,const uint8_t[16],uint64_t,int,const char *,const char *,int,int,int);
/* Read the private supervisor channel once; failed input leaves the bootstrap
 * unusable. accepted is changed only after the full bootstrap succeeds. */
int hc_frontend_bootstrap_receive(HCFrontendBootstrap *,int,unsigned,int,const char *,int,uid_t,const HCSessionExpected *,size_t,HCSessionRetention,int,const char *,const char *,int,int,int,HCLaunchRequest *);
/* The caller authenticates the request, game-profile root, frontend argument,
 * ROM, supervisor and descriptors and prevents concurrent replacement. This
 * opens isolated regions and installs them into the existing session owner. */
typedef struct {
 int rom_directory,inherited_rom,game_profile,binding_dir;
 uid_t uid;
 const char *rom_name,*rom_path,*profile_path,*frontend_sram,*binding_name;
 HCSessionRetention retention;
 int startup_fd,exit_fd,confirm_fd;
 /* Use the private per-ROM save directory for the binding record. */
 int binding_in_save_dir;
} HCFrontendIsolatedSpec;
int hc_frontend_bootstrap_isolated(HCFrontendBootstrap *,const HCFrontendIsolatedSpec *,const HCLaunchRequest *);
/* Correlates a single request received on a caller-owned private pipe with an
 * independently reviewed session. Matching data alone does not authenticate
 * either peer or authorize launch. The caller controls both pipe endpoints. */
int hc_frontend_bootstrap_receive_isolated(HCFrontendBootstrap *,const HCFrontendIsolatedSpec *,int,unsigned,const HCLaunchRequest *);
/* Main-thread check only; this does not authenticate the caller or authorize release. */
bool hc_frontend_bootstrap_ready(void);
/* Main-thread check only; callers must serialize bootstrap attempts. */
bool hc_frontend_bootstrap_available(void);
#ifdef HC_TEST_RELEASE_ONLY
/* Host-only: a match correlates the retained session; it does not prove
 * supervisor identity, liveness, safe shutdown, or authorize deployment. */
int hc_frontend_accept_release(unsigned timeout);
#endif
#endif
