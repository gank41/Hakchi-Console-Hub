#ifndef HC_STOCK_GAMEPLAY_H
#define HC_STOCK_GAMEPLAY_H
#include "stock-entry-start.h"
#include "stock-previous-save.h"
#include "stock-retained-image.h"
#include "stock-manager-image.h"
#include "stock-state-capture.h"
#include "stock-manager-state.h"
#include "stock-selected-state.h"
typedef struct HCConsoleSupport HCConsoleSupport;
/* Cohesive game-session sequencing. The caller authenticates the device,
 * game, files, inputs and prior-save ancestry, retains all owners, and drives
 * the clock and menu handoff. A recovery state must retain all evidence. */
enum {HC_GAMEPLAY_EMPTY,HC_GAMEPLAY_PREPARED,HC_GAMEPLAY_ACTIVE,HC_GAMEPLAY_ABORTING,HC_GAMEPLAY_STOPPED,HC_GAMEPLAY_FINISHED,HC_GAMEPLAY_FAILED,HC_GAMEPLAY_RECOVERY};
typedef struct {int target,autoload;HCVerifiedLaunch *program,*core,*config;const char *program_path,*core_path,*config_path;char *const *envp;HCConsoleSupport *support;} HCStockLaunchSpec;
typedef struct {HCStockEntryLaunch *entry;HCStockGameSession *session;HCStockControlSession *control;HCStockPrevious previous;int phase;HCConsoleSupport *support;HCTransition *transition;HCStockRetainedImage *retained_image;HCStockScreenshotReceipt *image_capture;HCStockTimeSeed *time_seed;int clock_enabled,clock_started,clock_stopped;HCPlaytimeInstant clock_start,clock_end;int manager_outputs;HCCompatibilityMenuCommand manager_original;HCStockStateReceipt *state_capture;HCStockStateArchive *state_archive;HCStateBytes *state_package;HCStockManagerState *manager_state;int manager_state_parent;HCStockSelectedState *selected_state;} HCStockGameplay;
#define HC_STOCK_GAMEPLAY_INITIALIZER {NULL,NULL,NULL,HC_STOCK_PREVIOUS_INITIALIZER,HC_GAMEPLAY_EMPTY,NULL,NULL,NULL,NULL,NULL,0,0,0,{0,0},{0,0},0,{0},NULL,NULL,NULL,NULL,-1,NULL}
int hc_stock_gameplay_prepare(HCStockGameplay *,HCStockEntryLaunch *);
/* Experimental screenshot/time request, optionally with a fresh rollback
 * output, captured before game start. Requires all handoff owners before
 * starting; does not enable target launch. */
int hc_stock_gameplay_prepare_manager_outputs(HCStockGameplay *,HCStockEntryLaunch *);
/* Bind the three already-authenticated descriptors from the same menu request.
 * Timing and target behavior remain unverified; callers retain the manager. */
int hc_stock_gameplay_bind_transition(HCStockGameplay *,HCTransition *);
/* Optional experimental image retention. Caller retains both objects, has
 * independently authenticated their session, and keeps paths exclusively
 * owned. Does not enable unsupported manager options or target launch. */
int hc_stock_gameplay_bind_retained_image(HCStockGameplay *,HCStockRetainedImage *,HCStockScreenshotReceipt *);
/* Optional captured-state retention for this exact live session. This does
 * not enable or publish the menu's unsupported native suspend options. */
int hc_stock_gameplay_bind_state_archive(HCStockGameplay *,HCStockStateReceipt *,HCStockStateArchive *);
/* Optional gzip package for the retained archive. The caller retains the
 * initially empty output through finalization and owns its returned bytes.
 * Packaging does not write or enable a native suspend point. */
int hc_stock_gameplay_bind_state_package(HCStockGameplay *,HCStateBytes *);
/* The caller retains an independently authenticated, exclusive manager parent
 * and the single-use publisher through finalization or recovery. */
int hc_stock_gameplay_bind_manager_state(HCStockGameplay *,HCStockManagerState *,int);
/* The selected-state evidence and all borrowed descriptors remain held until
 * launch and are not independently authenticated by this owner. */
int hc_stock_gameplay_bind_selected_state(HCStockGameplay *,HCStockSelectedState *);
/* Discover, stage and bind the exact selected prior state to this owner.
 * On -2, staged evidence or ownership remains and must be retained for
 * recovery; prior_out is changed only after successful binding. */
int hc_stock_gameplay_discover_selected_state(HCStockGameplay *,HCStockSelectedState *,int,int,const char *,HCLaunchRequest *);
/* Opt in before starting; the owner captures monotonic time immediately
 * before child launch and after confirmed clean shutdown. */
int hc_stock_gameplay_enable_time(HCStockGameplay *);
/* Bind a held, verified resumed-time snapshot before launch; the caller
 * retains it and its parent through the completion or recovery decision. */
int hc_stock_gameplay_bind_time_seed(HCStockGameplay *,HCStockTimeSeed *);
int hc_stock_gameplay_start(HCStockGameplay *,const HCStockLaunchSpec *);
/* 0 pending, 1 clean stop, -1 failed or quarantined. Even on failure the
 * caller must retain and supervise any possibly live child. */
int hc_stock_gameplay_poll(HCStockGameplay *,uint64_t,int *);
/* Preserve recovery evidence on any nonzero result. */
int hc_stock_gameplay_finish(HCStockGameplay *);
/* Experimental screenshot-only completion: finalize the retained image and
 * save, publish the image, then signal the manager. The entry gate still
 * refuses real menu screenshot requests; the caller owns the destination and
 * all records and must preserve them if completion fails. */
int hc_stock_gameplay_finish_with_image(HCStockGameplay *,HCStockManagerImage *,int manager_parent);
/* Experimental fresh-game image and play-time handoff uses the owner's
 * measured instants, with an optional bound fresh rollback output. Resumed
 * time uses the separate entry below; target launch remains gated. */
int hc_stock_gameplay_finish_with_image_time(HCStockGameplay *,HCStockManagerImage *,HCStockManagerTime *,int manager_parent);
/* Resumed time additionally requires the held snapshot selected before game
 * launch. Other manager outputs and target release remain unsupported. */
int hc_stock_gameplay_finish_with_resumed_time(HCStockGameplay *,HCStockManagerImage *,HCStockManagerTime *,HCStockTimeSeed *,int manager_parent);
#endif
