#ifndef HC_STOCK_RETAINED_IMAGE_H
#define HC_STOCK_RETAINED_IMAGE_H
#include "stock-screenshot-capture.h"
#include "autosave_target.h"
/* Experimental host-integrated retention. The caller authenticates the game,
 * manager, ROM, session and directories and excludes other writers through
 * finalization. Partial failure may leave durable records; preserve them. */
typedef struct {
 int attempted,published,retired;
 HCStockGameSession *game;
 HCStockScreenshotReceipt *capture;
 HCAutosaveTarget target;
 char image[1024],clock[1024],binding[47];
 uint8_t token[16];uint64_t epoch;
} HCStockRetainedImage;
#define HC_STOCK_RETAINED_IMAGE_INITIALIZER {0,0,0,NULL,NULL,HC_AUTOSAVE_TARGET_INITIALIZER,{0},{0},{0},{0},0}
/* Capture has completed and its child has exited cleanly. Retain the PNG in
 * the game's private save directory with a same-session recovery binding. */
int hc_stock_retained_image_prepare(HCStockRetainedImage *,HCStockGameSession *,HCStockControlSession *,HCStockScreenshotReceipt *);
/* After the clean exit and SRAM publication, retire only the SRAM journal.
 * The image and its journal remain pending for later manager publication. */
int hc_stock_retained_image_finish_save(HCStockRetainedImage *,HCStockGameSession *,HCStockControlSession *,HCStockScreenshotReceipt *,const void *,size_t);
/* Retire an unused SRAM checkpoint after a no-SRAM game while keeping the
 * retained image and its journal. Previous bytes or absence must be checked. */
int hc_stock_retained_image_finish_no_sram(HCStockRetainedImage *,HCStockGameSession *,HCStockControlSession *,HCStockScreenshotReceipt *,const void *,size_t);
/* Recheck the retained PNG and exact live session after save finalization.
 * This is not permission to write a manager path. */
int hc_stock_retained_image_recheck(HCStockRetainedImage *,HCStockGameSession *,HCStockControlSession *,HCStockScreenshotReceipt *);
/* After the manager has accepted the completed handoff, retire only the
 * finished screenshot's journal and empty checkpoint. The retained PNG and
 * binding stay. Interrupted cleanup must be reconciled before another game. */
int hc_stock_retained_image_retire(HCStockRetainedImage *,HCStockGameSession *,HCStockControlSession *,HCStockScreenshotReceipt *);
/* Close held descriptors only; does not remove files or recovery evidence. */
int hc_stock_retained_image_close(HCStockRetainedImage *);
#endif
