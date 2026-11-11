#ifndef HC_STOCK_SELECTED_STATE_H
#define HC_STOCK_SELECTED_STATE_H
#include "console-game.h"
#include "stock-game-session.h"
#include <sys/stat.h>

/* Experimental selection evidence. The caller independently authenticates
 * the console, selected prior session and directory ancestry, excludes all
 * writers, and keeps the borrowed objects/descriptors alive. A byte match is
 * correlation, not independent authentication or permission to launch. */
typedef struct {
 int ready,fd,parent,profiles;
 HCStockGameSession *game;HCConsoleRuntime *runtime;HCConsoleGame *menu;
 HCLaunchRequest prior;struct stat snapshot;
 char logical[1024],physical[1024],profiles_root[1024];
} HCStockSelectedState;
#define HC_STOCK_SELECTED_STATE_INITIALIZER {.fd=-1,.parent=-1,.profiles=-1}
/* Open the selected rollback parent beneath an already authenticated volatile
 * root. The returned descriptor is owned by the caller. No files are created. */
int hc_stock_selected_open_parent(const HCConsoleGame *,int,uid_t);
/* Open the console's fixed volatile root and resolve the selected parent.
 * The caller still authenticates the console and excludes path mutation. */
int hc_stock_selected_open_console_parent(const HCConsoleGame *,uid_t);
/* Identify one prior archived session whose state matches the selected bytes.
 * This is correlation only: the caller must authenticate the console and
 * profiles root, exclude writers and authorize any subsequent launch. */
int hc_stock_selected_state_identify(HCStockGameSession *,HCConsoleRuntime *,HCConsoleGame *,int,int,const char *,HCLaunchRequest *);
/* Discover and recheck the unique prior archive before staging the state. The
 * request output is assigned only after preparation succeeds. */
int hc_stock_selected_state_prepare_discovered(HCStockSelectedState *,HCStockGameSession *,HCConsoleRuntime *,HCConsoleGame *,int,int,const char *,HCLaunchRequest *);
/* Checks the manager-selected rollback input against a prior archive for the
 * same game, ROM and compatibility engine, then stages an exclusive private
 * autoload file. -2 means staged evidence may remain and must be retained. */
int hc_stock_selected_state_prepare(HCStockSelectedState *,HCStockGameSession *,HCConsoleRuntime *,HCConsoleGame *,int,int,const char *,const HCLaunchRequest *);
int hc_stock_selected_state_recheck(HCStockSelectedState *);
int hc_stock_selected_state_close(HCStockSelectedState *);
#endif
