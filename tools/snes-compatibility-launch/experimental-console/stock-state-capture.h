#ifndef HC_STOCK_STATE_CAPTURE_H
#define HC_STOCK_STATE_CAPTURE_H
#include "stock-game-session.h"
#include "checkpoint_receipt.h"
#include "autosave_target.h"
#include "state_codec.h"
/* Holds verified state bytes for the lifetime of the session. The caller must
 * authenticate the game, frontend, receipt, directories and pathname, exclude
 * other writers and retain the ROM and descriptors throughout. A receipt and
 * stable read are not proof that the state can load, is durable, belongs to a
 * genuine console, or is suitable for the native menu. No files are published.
 * This currently uses an experimental frontend command and is not a release. */
typedef struct {
 HCStockGameSession *game;int receipt,dir,phase,input_fd;pid_t child_pid;
 uint8_t token[16];uint64_t epoch;char game_code[12],rom_digest[65],name[128];
 struct stat receipt_snapshot,directory_snapshot,input_snapshot;
 HCCheckpoint checkpoint;HCReceiptReader reader;unsigned char *bytes;size_t length;
} HCStockStateReceipt;
#define HC_STOCK_STATE_RECEIPT_INITIALIZER {NULL,-1,-1,0,-1,-1,{0},0,{0},{0},{0},{0},{0},{0},{0},HC_RECEIPT_READER_INITIALIZER,NULL,0}
int hc_stock_state_receipt_init(HCStockStateReceipt *,HCStockGameSession *,int,int,const char *);
HCStockScreenshotCapture hc_stock_state_receipt_capture(HCStockStateReceipt *);
/* The archive holds one captured state in the game's private session. It is
 * recovery evidence only: the caller authenticates the console, excludes
 * writers, and must not infer native suspend-point compatibility. Partial
 * failures may leave files and require reconciliation. */
typedef struct {int attempted,published,parent;HCAutosaveTarget target;char path[1024];} HCStockStateArchive;
#define HC_STOCK_STATE_ARCHIVE_INITIALIZER {.parent=-1}
int hc_stock_state_archive_capture(HCStockStateArchive *,HCStockStateReceipt *,HCStockGameSession *,HCConsoleRuntime *,HCStockControlSession *);
int hc_stock_state_archive_recheck(HCStockStateArchive *,HCStockStateReceipt *,HCStockGameSession *,HCConsoleRuntime *,HCStockControlSession *);
/* Package only the matching, still-verified archive as a gzip state. The
 * caller owns the returned bytes and continues to exclude writers; this does
 * not publish a native suspend point or authorize a menu handoff. */
int hc_stock_state_archive_encode(HCStockStateArchive *,HCStockStateReceipt *,HCStockGameSession *,HCConsoleRuntime *,HCStockControlSession *,HCStateBytes *);
int hc_stock_state_archive_close(HCStockStateArchive *);
/* Call only after the control and producer have stopped. Does not remove files. */
void hc_stock_state_receipt_clear(HCStockStateReceipt *);
#endif
