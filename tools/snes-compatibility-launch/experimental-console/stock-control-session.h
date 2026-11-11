#ifndef HC_STOCK_CONTROL_SESSION_H
#define HC_STOCK_CONTROL_SESSION_H
#include "stock-reset-input.h"
#include "stock-power-input.h"
#include "stock-exit-owner.h"
#include "transitions.h"
/* Caller authenticates device/key and owns the session, descriptors and
 * monotonic clock. This component does not discover power/RESET devices,
 * discover a manager, publish saves, or authorize console launch. */
/* Reason is an observation, not permission to power off or restart the menu.
 * A caller must first receive a clean completion and authenticate the inputs.
 * A power event supersedes RESET, including while the child is exiting. */
typedef enum {HC_STOCK_CONTROL_NONE=0,HC_STOCK_CONTROL_RESET,HC_STOCK_CONTROL_POWER} HCStockControlReason;
/* The caller owns this capture operation for the whole game. poll returns 1
 * only after a matching receipt and fresh screenshot have been verified, 0
 * while pending and -1 on failure. This interface does not provide a capture
 * implementation, authenticate paths, or authorize publication. */
typedef struct {void *context;int (*begin)(void *,HCStockSaveSession *);int (*poll)(void *,HCStockSaveSession *,uint64_t);} HCStockScreenshotCapture;
typedef struct {HCStockResetInput *reset;HCStockPowerInput *power;HCStockSaveSession *save;HCStockExitOwner exit_owner;int started,failed,finished;HCStockControlReason reason;HCTransition *transition;HCStockScreenshotCapture *screenshot;int capturing;uint64_t capture_deadline,capture_last;int manager_reset,manager_mode;int (*manager_probe)(void);HCStockScreenshotCapture *state;int capture_kind;} HCStockControlSession;
#define HC_STOCK_CONTROL_SESSION_INITIALIZER {NULL,NULL,NULL,HC_STOCK_EXIT_OWNER_INITIALIZER,0,0,0,HC_STOCK_CONTROL_NONE,NULL,NULL,0,0,0,0,0,NULL,NULL,0}
/* Bind before the frontend starts, so RESET and power can be owned before
 * seeding or spawning. step refuses to run until the session is running. */
int hc_stock_control_prepare(HCStockControlSession *,HCStockResetInput *,HCStockSaveSession *);
int hc_stock_control_init(HCStockControlSession *,HCStockResetInput *,HCStockSaveSession *);
/* The probe returns a latched RESET observation (>0), no event (0), or an
 * error (<0). The caller must install and retain the signal owner before any
 * manager interaction. This mode does not poll a physical RESET input. */
int hc_stock_control_prepare_manager(HCStockControlSession *,HCStockSaveSession *,int (*)(void));
int hc_stock_control_attach_power(HCStockControlSession *,HCStockPowerInput *);
/* Attach before gameplay; screenshot completion precedes child termination. */
int hc_stock_control_attach_screenshot(HCStockControlSession *,HCStockScreenshotCapture *);
/* Optional state capture runs before the screenshot and before child exit.
 * The caller must provide a session-bound implementation and keep it alive.
 * This does not publish a suspend point or enable unsupported menu options. */
int hc_stock_control_attach_state(HCStockControlSession *,HCStockScreenshotCapture *);
/* Attach only after the original manager's first-frame wait has completed. */
int hc_stock_control_attach_transition(HCStockControlSession *,HCTransition *);
/* Request supervised termination after a failed startup that retained a live
 * child. A successful request starts polling; it never authorizes a save.
 * If the request cannot establish ownership, preserve the session for review. */
int hc_stock_control_abort(HCStockControlSession *,uint64_t);
/* Called by the session owner, outside the signal handler, after observing
 * the original menu manager's RESET signal.  Repeated requests coalesce. */
int hc_stock_control_manager_reset(HCStockControlSession *);
/* 0 running/exit pending, 1 clean reaped, -1 failure. A failure can retain an
 * owned child; callers must inspect and supervise rather than abandon it. */
int hc_stock_control_step(HCStockControlSession *,uint64_t,int *);
/* Recheck both input streams after exit and before the next session action.
 * The caller retains descriptors and must authenticate their identity. */
int hc_stock_control_refresh_finished(HCStockControlSession *);
#endif
