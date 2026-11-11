#ifndef HC_STOCK_GAME_SESSION_H
#define HC_STOCK_GAME_SESSION_H
#include "console-game.h"
#include "stock-save-session.h"
#include "stock-control-session.h"
/* Inert compatibility-game session preparation. The caller authenticates the
 * menu and ROM digest independently and exclusively controls all paths and
 * executable resources. No gameplay is released by this API. On failure,
 * recovery records may remain; close releases descriptors but deletes nothing. */
typedef struct {HCStockSaveSession save;HCVerifiedLaunch rom;int fault,detected_no_sram,finalized,save_lock;char game[12],binding[81],detected_core_sha[65];uint8_t token[16];uint64_t epoch;unsigned char *autoload_bytes;size_t autoload_length;struct stat autoload_snapshot;} HCStockGameSession;
#define HC_STOCK_GAME_SESSION_INITIALIZER {HC_STOCK_SAVE_SESSION_INITIALIZER,HC_VERIFIED_LAUNCH_INITIALIZER,0,0,0,-1,{0},{0},{0},{0},0,NULL,0,{0}}
int hc_stock_game_prepare(HCStockGameSession *,HCConsoleGame *,int,const char *const [],const char *,int,int,const char *,size_t,const char *,const uint8_t[16],uint64_t,const uint8_t[16]);
/* Duplicate the runtime's already-held lock only after matching the save
 * directory. Caller retains its lock and excludes other writers throughout. */
int hc_stock_game_prepare_with_lock(HCStockGameSession *,HCConsoleGame *,int,const char *const [],const char *,int,int,const char *,size_t,const char *,const uint8_t[16],uint64_t,const uint8_t[16],int);
int hc_stock_game_recheck(HCStockGameSession *);
/* Verify the captured startup state before consuming a manager event or
 * starting a frontend. Caller continues to exclude other writers. */
int hc_stock_game_autoload_ready(HCStockGameSession *,int);
/* Caller checks the game-bound session and retains exclusive path access. */
int hc_stock_game_seed_stage(HCStockGameSession *);
/* Caller still authenticates executable, core, configuration and their
 * paths; these wrappers enforce the retained ROM/session recheck. */
int hc_stock_game_start_rom(HCStockGameSession *,int,const char *,char *const [],char *const []);
int hc_stock_game_start_reviewed(HCStockGameSession *,int,HCVerifiedLaunch *,const char *,HCVerifiedLaunch *,const char *,HCVerifiedLaunch *,const char *,int,char *const []);
/* Seed an initially empty session from its own game-bound save before launch. */
int hc_stock_game_start_seeded_reviewed(HCStockGameSession *,int,HCVerifiedLaunch *,const char *,HCVerifiedLaunch *,const char *,HCVerifiedLaunch *,const char *,int,char *const []);
int hc_stock_game_validate_no_sram(HCStockGameSession *);
/* Caller supplies independently authenticated original bytes (or NULL/0 for
 * an originally absent save), has stopped every writer, and retains exclusive
 * parent access. The supplied previous state must also match the snapshot
 * captured when this live session seeded its stage. On success this closes
 * the save owner; on refusal or partial
 * cleanup it retains the owner and snapshot for supervised reconciliation.
 * -2 means cleanup may be partial. It does not delete the binding. */
int hc_stock_game_finish_no_sram(HCStockGameSession *,const void *,size_t);
/* Use the pre-launch snapshot retained by the seeded session. It is only
 * in memory; crash recovery still requires independently retained evidence. */
int hc_stock_game_finish_no_sram_captured(HCStockGameSession *);
/* The control session must match this game and have observed a clean,
 * non-timed-out exit. Caller still authenticates input and excludes writers. */
int hc_stock_game_finish_no_sram_after_exit(HCStockGameSession *,HCStockControlSession *);
int hc_stock_game_publish_stage(HCStockGameSession *);
/* Only the matching control owner can authorize publication after a clean
 * shutdown. Caller still excludes writers and authenticates all paths. */
int hc_stock_game_publish_after_exit(HCStockGameSession *,HCStockControlSession *);
/* Caller authenticates and independently retains both snapshots, has stopped
 * all writers, and holds exclusive access. Returns -2 on partial cleanup.
 * This does not provide a durable backup or restart recovery. */
int hc_stock_game_finish_published(HCStockGameSession *,const void *,size_t,const void *,size_t);
/* Use this live session's retained publication bytes for the current save.
 * The caller still authenticates the independently retained previous state,
 * stops every writer and holds exclusive access. The in-memory copy cannot
 * support recovery after a process or power interruption. */
int hc_stock_game_finish_published_captured(HCStockGameSession *,const void *,size_t);
/* Recheck the still-owned control streams before retiring save recovery. */
int hc_stock_game_finish_published_after_exit(HCStockGameSession *,HCStockControlSession *,const void *,size_t);
/* Exclude concurrent descriptor-table reuse during close/retry. If closing
 * the save lock fails, a still-open descriptor remains owned for retry. */
int hc_stock_game_close(HCStockGameSession *);
#endif
