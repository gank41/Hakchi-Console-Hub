#ifndef HC_STOCK_MANAGER_IMAGE_H
#define HC_STOCK_MANAGER_IMAGE_H
#include "stock-retained-image.h"
#include "playtime.h"
#include <sys/stat.h>
/* Experimental single-use manager-image publication. The caller authenticates
 * the console, menu, session and pinned directories and excludes all other
 * writers. Failure may retain records; do not retry or delete them blindly. */
typedef struct {int attempted,published;HCAutosaveTarget target;char path[1024],binding[46];} HCStockManagerImage;
#define HC_STOCK_MANAGER_IMAGE_INITIALIZER {0,0,HC_AUTOSAVE_TARGET_INITIALIZER,{0},{0}}
/* Writes only a previously absent manager image after the matching SRAM
 * session is finalized and its PNG is retained. Existing targets are refused.
 * Recovery records and the retained PNG remain after success. */
int hc_stock_manager_image_publish(HCStockManagerImage *,HCStockRetainedImage *,HCStockGameSession *,HCStockControlSession *,HCStockScreenshotReceipt *,HCConsoleRuntime *,HCConsoleGame *,int);
/* Close held descriptors only; does not remove files or recovery evidence. */
int hc_stock_manager_image_close(HCStockManagerImage *);
typedef struct {int attempted,published;HCAutosaveTarget target;char path[1024];} HCStockManagerTime;
#define HC_STOCK_MANAGER_TIME_INITIALIZER {0,0,HC_AUTOSAVE_TARGET_INITIALIZER,{0}}
/* Experimental fresh-session time output: caller independently authenticates
 * monotonic start/end instants and owns the same manager paths exclusively.
 * Resume/load-time and existing destinations are refused. A failed attempt
 * may retain recovery evidence. This does not enable console gameplay. */
int hc_stock_manager_time_publish(HCStockManagerTime *,HCStockManagerImage *,HCStockRetainedImage *,HCStockGameSession *,HCStockControlSession *,HCStockScreenshotReceipt *,HCConsoleRuntime *,HCConsoleGame *,int,HCPlaytimeInstant,HCPlaytimeInstant);
int hc_stock_manager_time_close(HCStockManagerTime *);
/* Read-only, held snapshot of a manager-selected resume time. The caller
 * authenticates the menu and holds the source directory exclusively until
 * close. A distinct output must be absent; a matching input/output retains
 * the exact previous bytes in a journaled private checkpoint. */
typedef struct {int ready,fd,parent,same_target,backup_attempted,backup_retained;uint64_t prior,epoch;uint8_t token[16];char game[12],digest[65],path[1024],backup_path[1024];unsigned char original[21];size_t original_length;struct stat snapshot;HCStockGameSession *session;HCConsoleRuntime *runtime,*backup_runtime;HCConsoleGame *menu;HCAutosaveTarget backup;} HCStockTimeSeed;
#define HC_STOCK_TIME_SEED_INITIALIZER {.fd=-1,.parent=-1}
int hc_stock_time_seed_open(HCStockTimeSeed *,HCStockGameSession *,HCConsoleRuntime *,HCConsoleGame *,int);
int hc_stock_time_seed_recheck(HCStockTimeSeed *,HCStockGameSession *,HCConsoleRuntime *,HCConsoleGame *,int);
/* A journaled copy in the selected game's persistent session workspace.
 * The caller authenticates and exclusively holds that workspace; failure can
 * leave evidence and must not be retried as a fresh session. */
int hc_stock_time_seed_retain(HCStockTimeSeed *,HCStockGameSession *,HCConsoleRuntime *);
int hc_stock_time_seed_backup_recheck(HCStockTimeSeed *,HCStockGameSession *,HCConsoleRuntime *);
int hc_stock_time_seed_close(HCStockTimeSeed *);
int hc_stock_manager_time_publish_resumed(HCStockManagerTime *,HCStockManagerImage *,HCStockRetainedImage *,HCStockGameSession *,HCStockControlSession *,HCStockScreenshotReceipt *,HCConsoleRuntime *,HCConsoleGame *,HCStockTimeSeed *,int,HCPlaytimeInstant,HCPlaytimeInstant);
#endif
