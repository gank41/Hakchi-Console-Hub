#ifndef HC_STOCK_SAVE_SESSION_H
#define HC_STOCK_SAVE_SESSION_H
#include "child_process.h"
#include "autosave_target.h"
#include "verified-launch.h"
#include <stddef.h>
#include <stdint.h>
#include <sys/stat.h>
/* Prototype seam for one stock-frontend SRAM session, not an enabled console
 * launcher. Caller authenticates game/ROM/program/args and save path, supplies
 * fresh secure tokens, isolates the child and all writers, and keeps parent
 * access exclusive. Publishing requires independently checked bytes from the
 * reaped child; process exit alone does not prove a successful save. Any failed
 * prepare or publish can leave recovery records; never silently remove them.
 * The caller must exclude other threads and signal handlers from changing or
 * reusing descriptors during start, polling and session close. A
 * remaining report_write is quarantined until the child is reaped and the
 * caller explicitly closes the session. */
enum {HC_STOCK_EMPTY,HC_STOCK_PREPARED,HC_STOCK_RUNNING,HC_STOCK_REAPED_CLEAN,HC_STOCK_REAPED_FAILED,HC_STOCK_PUBLISHED,HC_STOCK_FAILED,HC_STOCK_CLOSED,HC_STOCK_REAPED_NO_SRAM};
typedef struct {int phase,requested,stage_dir,rom_fault,config_autoload;size_t stage_size;HCChild child;HCAutosaveTarget target;HCVerifiedLaunch *rom,*program,*core,*config;char identity[1024],stage_name[128],program_path[1024],core_path[1024],config_path[1024],config_dir[1024];int stage_snapshot_taken,stage_was_present;struct stat stage_before;int report_read,report_write,report_required,report_code;unsigned char *initial_bytes;size_t initial_length;int initial_valid,initial_present;unsigned char *published_bytes;size_t published_length;int cooperative_lock,child_wait_unknown,screenshot_write,screenshot_enabled;struct stat screenshot_snapshot;} HCStockSaveSession;
#define HC_STOCK_SAVE_SESSION_INITIALIZER {HC_STOCK_EMPTY,0,-1,0,0,0,HC_CHILD_INITIALIZER,HC_AUTOSAVE_TARGET_INITIALIZER,NULL,NULL,NULL,NULL,{0},{0},{0},{0},{0},{0},0,0,{0},-1,-1,0,0,NULL,0,0,0,NULL,0,-1,0,-1,0,{0}}
int hc_stock_save_prepare(HCStockSaveSession *,int,const char *,const char *,const char *,const uint8_t[16],uint64_t,const uint8_t[16],const char *);
/* Pair the battery identity with its clock identity in the recovery record.
 * This records the clock path only; it does not open or write a clock save. */
int hc_stock_save_prepare_pair(HCStockSaveSession *,int,const char *,const char *,const char *,const uint8_t[16],uint64_t,const uint8_t[16],const char *,const char *);
/* Bind a private session directory and bounded save filename before launch.
 * Caller independently proves it corresponds to the reviewed ROM and config,
 * and verifies the frontend actually completed this save. */
/* Check the caller-supplied staging destination before creating recovery records.
 * Binding rechecks it after preparation; callers still exclude concurrent changes. */
int hc_stock_save_validate_stage(int stage, int parent, const char *name, size_t size);
int hc_stock_save_bind_stage(HCStockSaveSession *,int,const char *,size_t);
/* Copy an existing matching battery save into an empty, private stage. Returns
 * 1 if no save exists, 0 after a verified copy, and -1 on conflict or error.
 * Caller authenticates paths and holds exclusive access. On partial failure
 * stage files may remain and must not be silently removed. */
int hc_stock_save_seed_stage(HCStockSaveSession *);
int hc_stock_save_start(HCStockSaveSession *,const char *,char *const [],char *const []);
/* Transfer ownership of a private screenshot-receipt pipe writer to this
 * prepared session. The caller binds the read end and session token to the
 * same authenticated game. On failure the caller retains the descriptor. */
int hc_stock_save_take_screenshot_receipt(HCStockSaveSession *,int);
/* Holds a borrowed verified ROM through child reaping. Caller guarantees its
 * lifetime and authenticates program/core/config, including save paths. */
int hc_stock_save_start_rom(HCStockSaveSession *,HCVerifiedLaunch *,int,const char *,char *const [],char *const []);
/* Caller independently authenticates the exact program, core and config
 * digests and their private parents and keeps each pointer and path stable.
 * Config semantics, manager protocol and firmware eligibility are not proved. */
/* Check all reviewed launch inputs before copying any prior save. */
int hc_stock_save_preflight_reviewed(HCStockSaveSession *,HCVerifiedLaunch *,int,HCVerifiedLaunch *,const char *,HCVerifiedLaunch *,const char *,HCVerifiedLaunch *,const char *,int,char *const []);
int hc_stock_save_start_reviewed(HCStockSaveSession *,HCVerifiedLaunch *,int,HCVerifiedLaunch *,const char *,HCVerifiedLaunch *,const char *,HCVerifiedLaunch *,const char *,int,char *const []);
int hc_stock_save_signal(HCStockSaveSession *,int);
int hc_stock_save_poll(HCStockSaveSession *,int *);
/* No-SRAM outcome can be cleaned up only if the staged SRAM stayed untouched. */
int hc_stock_save_validate_no_sram(HCStockSaveSession *);
int hc_stock_save_publish_stage(HCStockSaveSession *);
/* A lost-child result without waitpid evidence keeps cleanup refused and the
 * caller-owned save lock held; it requires external inspection. Unconsumed
 * reaped status also blocks close. The owner must first retry closing child
 * input and explicitly retrieve the status with hc_child_take_reaped; this
 * does not mark a failed save as clean or authorize publication. */
int hc_stock_save_close(HCStockSaveSession *);
#endif
