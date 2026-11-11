#ifndef HC_STOCK_ENTRY_START_H
#define HC_STOCK_ENTRY_START_H
#include "stock-runtime-bridge.h"
#include <string.h>
/* Shared launch sequence, currently exercised on the host only. The caller
 * authenticates executables, paths, input devices and the menu request and
 * keeps exclusive access. A failed preparation may leave recovery evidence. */
/* The current battery-only path must reject manager checkpoint, screenshot,
 * rollback and play-time requests before creating save/recovery records. */
static inline int hc_stock_entry_command_supported(const HCCompatibilityMenuCommand *command){
 if(!command)return 0;
 const unsigned pending=(1u<<HC_SCREENSHOT)|(1u<<HC_ROLLBACK_OUT)|(1u<<HC_ROLLBACK_MODE)|(1u<<HC_SAVE)|(1u<<HC_ROLLBACK_IN)|(1u<<HC_LOAD)|(1u<<HC_LOAD_TIME)|(1u<<HC_SAVE_TIME);
 return !command->checkpoint.have_save&&!command->checkpoint.have_image&&!command->checkpoint.have_load&&!(command->manager.present&pending);
}
/* Experimental screenshot + time and an optional separately held rollback
 * output. Loading and other suspend/rollback modes remain unsupported. */
static inline int hc_stock_entry_command_manager_outputs(const HCCompatibilityMenuCommand *command){
 const unsigned required=(1u<<HC_WAIT)|(1u<<HC_START)|(1u<<HC_FINISH)|(1u<<HC_SCREENSHOT)|(1u<<HC_SAVE_TIME);
 if(!command||(command->manager.present&required)!=required||!command->checkpoint.have_image||!command->time.have_save||
    (!!command->time.have_load!=!!(command->manager.present&(1u<<HC_LOAD_TIME))))return 0;
 const char *image=command->checkpoint.image,*save=command->time.save,*load=command->time.load;
 if(!memchr(image,0,HC_ARGUMENT_BYTES)||!memchr(save,0,HC_ARGUMENT_BYTES)||
    (command->time.have_load&&!memchr(load,0,HC_ARGUMENT_BYTES)))return 0;
 const char *image_slash=strrchr(image,'/'),*save_slash=strrchr(save,'/');
 if(!image_slash||!save_slash||!image_slash[1]||!save_slash[1]||image_slash==image||
    image_slash-image!=save_slash-save||memcmp(image,save,(size_t)(image_slash-image)))return 0;
 if(command->time.have_load){const char *load_slash=strrchr(load,'/');
  if(!load_slash||!load_slash[1]||load_slash-load!=image_slash-image||memcmp(image,load,(size_t)(image_slash-image)))return 0;}
 HCCompatibilityMenuCommand copy=*command;
 copy.checkpoint.have_image=0;copy.time.have_load=0;copy.time.have_save=0;
 copy.manager.present&=~((1u<<HC_SCREENSHOT)|(1u<<HC_LOAD_TIME)|(1u<<HC_SAVE_TIME));
 if(copy.checkpoint.have_save){
  const char *state=copy.checkpoint.save,*rollback=copy.manager.values[HC_ROLLBACK_OUT];
  if(!(copy.manager.present&(1u<<HC_ROLLBACK_OUT))||!memchr(state,0,HC_ARGUMENT_BYTES)||!memchr(rollback,0,HC_ARGUMENT_BYTES))return 0;
  size_t n=strlen(rollback);const char *slash=strrchr(state,'/');
  if(n==0||n+10>=HC_ARGUMENT_BYTES||strncmp(state,rollback,n)||strcmp(state+n,"/savestate")||!slash||
     (slash-state==image_slash-image&&!memcmp(state,image,(size_t)(slash-state))))return 0;
  copy.checkpoint.have_save=0;copy.manager.present&=~(1u<<HC_ROLLBACK_OUT);
 }
 if(copy.checkpoint.have_load){
  const char *state=copy.checkpoint.load,*rollback=copy.manager.values[HC_ROLLBACK_IN];
  if(!command->checkpoint.have_save||!(copy.manager.present&(1u<<HC_ROLLBACK_IN))||!memchr(state,0,HC_ARGUMENT_BYTES)||!memchr(rollback,0,HC_ARGUMENT_BYTES))return 0;
  size_t n=strlen(rollback);if(!n||n+10>=HC_ARGUMENT_BYTES||strncmp(state,rollback,n)||strcmp(state+n,"/savestate"))return 0;
  copy.checkpoint.have_load=0;copy.manager.present&=~(1u<<HC_ROLLBACK_IN);
 }
 return hc_stock_entry_command_supported(&copy);
}
typedef struct {HCStockGameSession *session;HCConsoleRuntime *runtime;HCConsoleGame *game;HCStockControlSession *control;HCStockResetInput *reset;HCStockPowerInput *power;int reset_fd,power_fd;uint16_t reset_key,power_type,power_code;uint32_t power_value;int ready,start_failed,manager_mode;int (*manager_probe)(void);} HCStockEntryLaunch;
#define HC_STOCK_ENTRY_LAUNCH_INITIALIZER {NULL,NULL,NULL,NULL,NULL,NULL,-1,-1,0,0,0,0,0,0,0,NULL}
int hc_stock_entry_prepare(HCStockEntryLaunch *,HCStockGameSession *,HCConsoleRuntime *,HCConsoleGame *,int,const char *const [],const char *,int,int,const char *,HCSizeProbe *,HCVerifiedLaunch *);
/* Validate before creating any session workspace, then revalidate at
 * preparation. The caller still owns the game, ROM and manager arguments. */
int hc_stock_entry_validate_save_only(HCConsoleGame *,int,const char *const []);
int hc_stock_entry_validate_manager_outputs(HCConsoleGame *,int,const char *const []);
int hc_stock_entry_prepare_manager_outputs(HCStockEntryLaunch *,HCStockGameSession *,HCConsoleRuntime *,HCConsoleGame *,int,const char *const [],const char *,int,int,const char *,HCSizeProbe *,HCVerifiedLaunch *);
/* Use for the battery-only gameplay owner: reject unimplemented manager
 * features before consuming the probe or creating save/recovery records. */
int hc_stock_entry_prepare_save_only(HCStockEntryLaunch *,HCStockGameSession *,HCConsoleRuntime *,HCConsoleGame *,int,const char *const [],const char *,int,int,const char *,HCSizeProbe *,HCVerifiedLaunch *);
/* The caller authenticates the power input and physical switch state and
 * either owns the physical RESET input or continuously observes the manager's
 * signal. It retains those sources through startup and shutdown. */
int hc_stock_entry_bind_controls(HCStockEntryLaunch *,HCStockControlSession *);
/* A failure can occur after a child has started. The pre-bound control owner
 * remains associated with the save; the entry requests an abort if a monotonic
 * time is available. The caller must continue polling any active abort, or
 * initiate one after a clock failure, and retain all resources until reaped.
 * Failure never authorizes publication. */
int hc_stock_entry_start(HCStockEntryLaunch *,HCStockGameSession *,HCConsoleRuntime *,HCConsoleGame *,int,HCVerifiedLaunch *,const char *,HCVerifiedLaunch *,const char *,HCVerifiedLaunch *,const char *,int,char *const []);
/* Advance failed-start cleanup using the same bound control owner. Returns 0
 * while the child is owned and pending, 1 after a confirmed reap, and -1 if
 * ownership or status is uncertain. No result permits save publication. */
int hc_stock_entry_failed_start_poll(HCStockEntryLaunch *,uint64_t,int *);
#endif
