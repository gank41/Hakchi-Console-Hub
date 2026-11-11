#ifndef HC_STOCK_SCREENSHOT_CAPTURE_H
#define HC_STOCK_SCREENSHOT_CAPTURE_H
#include "stock-game-session.h"
#include "checkpoint_receipt.h"
/* Private single-image staging for a caller-authenticated game session.
 * Caller pins and exclusively owns the empty 0700 directory, pipes, producer,
 * session and descriptor table until control and all callbacks have stopped.
 * Session tokens must be unpredictable and never reused, including after restart.
 * The game code and digest checks enforce consistency only; the caller must
 * authenticate the selected ROM and retain it separately. Receipt and PNG
 * verification do not prove target pixels, durability or publication; this
 * component does not enable the console launcher. */
typedef struct {HCStockGameSession *game;int receipt,dir,phase;uint8_t token[16];uint64_t epoch;HCCheckpoint checkpoint;HCReceiptReader reader;unsigned char *image;size_t image_length;char game_code[12],rom_digest[65];struct stat receipt_snapshot,directory_snapshot,input_snapshot;int input_fd;pid_t child_pid;} HCStockScreenshotReceipt;
#define HC_STOCK_SCREENSHOT_RECEIPT_INITIALIZER {NULL,-1,-1,0,{0},0,{0},HC_RECEIPT_READER_INITIALIZER,NULL,0,{0},{0},{0},{0},{0},-1,-1}
int hc_stock_screenshot_receipt_init(HCStockScreenshotReceipt *,HCStockGameSession *,int,int);
HCStockScreenshotCapture hc_stock_screenshot_receipt_capture(HCStockScreenshotReceipt *);
/* Create and bind one receipt pipe to the same prepared game and control
 * session. Both outputs must initially be -1 and may contain caller-owned
 * descriptors on failure. On success the save session owns the writer and
 * the writer output is -1; the caller owns the reader through shutdown.
 * The caller authenticates the game, paths and frontend session. */
int hc_stock_screenshot_bind_session(HCStockGameSession *,HCStockControlSession *,HCStockScreenshotReceipt *,HCStockScreenshotCapture *,int,int *,int *);
/* Only after control, producer and callbacks stop. Does not delete files. */
void hc_stock_screenshot_receipt_clear(HCStockScreenshotReceipt *);
#endif
