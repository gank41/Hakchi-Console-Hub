#define _POSIX_C_SOURCE 200809L
#include "stock-entry-start.h"
#include "stock-screenshot-signal.h"
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <time.h>
#if defined(HC_TEST_POSTSPAWN_FAILURE) && defined(__arm__)
#error "Post-spawn injection is host-only"
#endif
int hc_stock_entry_prepare(HCStockEntryLaunch *entry,HCStockGameSession *session,HCConsoleRuntime *runtime,HCConsoleGame *game,int argc,const char *const argv[],const char *profiles,int parent,int stage,const char *name,HCSizeProbe *probe,HCVerifiedLaunch *core){
 if(!entry||entry->ready||entry->session||entry->start_failed||!session||!runtime||!game){errno=EINVAL;return -1;}
 /* A failed operation can retain recovery records; this entry is single-use. */
 entry->session=session;entry->runtime=runtime;entry->game=game;
 if(hc_stock_game_prepare_detected(session,runtime,game,argc,argv,profiles,parent,stage,name,probe,core))return -1;
 if(hc_console_game_prepare_manager_record(game,runtime,argc,argv))return -1;
 entry->ready=1;return 0;
}
static int validate_command(HCConsoleGame *game,int argc,const char *const argv[],int manager_outputs){
 HCCompatibilityMenuCommand parsed;
 if(!game||hc_parse_compatibility_menu_command(argc,argv,&parsed)||
    strncmp(parsed.game,game->command.game,sizeof parsed.game)||strncmp(parsed.rom_name,game->command.rom_name,sizeof parsed.rom_name)||
    strncmp(parsed.digest,game->command.digest,sizeof parsed.digest)||
    strncmp(parsed.saves.sram,game->command.saves.sram,sizeof parsed.saves.sram)||strncmp(parsed.saves.rtc,game->command.saves.rtc,sizeof parsed.saves.rtc)||
    parsed.manager.present!=game->command.manager.present||parsed.manager.wait_fd!=game->command.manager.wait_fd||
    parsed.manager.start_fd!=game->command.manager.start_fd||parsed.manager.finish_fd!=game->command.manager.finish_fd||
    parsed.checkpoint.have_save!=game->command.checkpoint.have_save||parsed.checkpoint.have_image!=game->command.checkpoint.have_image||parsed.checkpoint.have_load!=game->command.checkpoint.have_load||
    strncmp(parsed.checkpoint.save,game->command.checkpoint.save,sizeof parsed.checkpoint.save)||
    strncmp(parsed.checkpoint.image,game->command.checkpoint.image,sizeof parsed.checkpoint.image)||strncmp(parsed.checkpoint.load,game->command.checkpoint.load,sizeof parsed.checkpoint.load)||
    parsed.time.have_load!=game->command.time.have_load||parsed.time.have_save!=game->command.time.have_save||
    strncmp(parsed.time.load,game->command.time.load,sizeof parsed.time.load)||
    strncmp(parsed.time.save,game->command.time.save,sizeof parsed.time.save)){errno=EINVAL;return -1;}
 for(unsigned i=0;i<HC_OPTION_COUNT;i++)if((parsed.manager.present&(1u<<i))&&strncmp(parsed.manager.values[i],game->command.manager.values[i],HC_ARGUMENT_BYTES)){errno=EINVAL;return -1;}
 if(!(manager_outputs?hc_stock_entry_command_manager_outputs(&parsed):hc_stock_entry_command_supported(&parsed))){errno=ENOTSUP;return -1;}
 return 0;
}
int hc_stock_entry_validate_save_only(HCConsoleGame *game,int argc,const char *const argv[]){return validate_command(game,argc,argv,0);}
int hc_stock_entry_validate_manager_outputs(HCConsoleGame *game,int argc,const char *const argv[]){return validate_command(game,argc,argv,1);}
int hc_stock_entry_prepare_manager_outputs(HCStockEntryLaunch *entry,HCStockGameSession *session,HCConsoleRuntime *runtime,HCConsoleGame *game,int argc,const char *const argv[],const char *profiles,int parent,int stage,const char *name,HCSizeProbe *probe,HCVerifiedLaunch *core){
 if(!entry||!session||!runtime){errno=EINVAL;return -1;}
 if(hc_stock_entry_validate_manager_outputs(game,argc,argv))return -1;
 return hc_stock_entry_prepare(entry,session,runtime,game,argc,argv,profiles,parent,stage,name,probe,core);
}
int hc_stock_entry_prepare_save_only(HCStockEntryLaunch *entry,HCStockGameSession *session,HCConsoleRuntime *runtime,HCConsoleGame *game,int argc,const char *const argv[],const char *profiles,int parent,int stage,const char *name,HCSizeProbe *probe,HCVerifiedLaunch *core){
 if(!entry||!session||!runtime){errno=EINVAL;return -1;}
 if(hc_stock_entry_validate_save_only(game,argc,argv))return -1;
 return hc_stock_entry_prepare(entry,session,runtime,game,argc,argv,profiles,parent,stage,name,probe,core);
}
static int input_ready(int fd){
 int flags=fcntl(fd,F_GETFL);return fd>=3&&flags>=0&&(flags&O_ACCMODE)==O_RDONLY&&(flags&O_NONBLOCK);
}
int hc_stock_entry_bind_controls(HCStockEntryLaunch *entry,HCStockControlSession *control){
 if(!entry||!entry->ready||!entry->session||entry->control||!control||control->save!=&entry->session->save||control->save->phase!=HC_STOCK_PREPARED||
    control->transition||control->started||control->failed||control->finished||control->reason!=HC_STOCK_CONTROL_NONE||control->exit_owner.phase||control->exit_owner.save||
    control->exit_owner.deadline||control->exit_owner.last||control->exit_owner.timed_out||control->exit_owner.kill_sent){errno=EINVAL;return -1;}
 HCStockResetInput *reset=control->reset;HCStockPowerInput *power=control->power;
 if(entry->reset||entry->power||!power||(control->manager_mode!=0&&control->manager_mode!=1)||
    (control->manager_mode?(reset!=NULL||!control->manager_probe):(control->manager_probe||!reset||reset->fd==power->fd||!input_ready(reset->fd)||!reset->key||reset->key>767||reset->failed||reset->used||reset->pressed))||
    !input_ready(power->fd)||
    power->type!=1||!power->code||power->code>767||power->value>1||power->failed||power->used||power->triggered){errno=EINVAL;return -1;}
 entry->control=control;entry->reset=reset;entry->power=power;entry->reset_fd=reset?reset->fd:-1;entry->power_fd=power->fd;
 entry->reset_key=reset?reset->key:0;entry->manager_mode=control->manager_mode;entry->manager_probe=control->manager_probe;entry->power_type=power->type;entry->power_code=power->code;entry->power_value=power->value;return 0;
}
int hc_stock_entry_start(HCStockEntryLaunch *entry,HCStockGameSession *session,HCConsoleRuntime *runtime,HCConsoleGame *game,int target,HCVerifiedLaunch *program,const char *program_path,HCVerifiedLaunch *core,const char *core_path,HCVerifiedLaunch *config,const char *config_path,int autoload,char *const envp[]){
 if(!entry||!entry->ready||!session||!runtime||!game||entry->session!=session||entry->runtime!=runtime||entry->game!=game||!runtime->stock_claimed||!game->rom.ready||!session->rom.ready||strcmp(session->game,game->command.game)||strcmp(runtime->request.game,game->command.game)||strcmp(runtime->request.digest,game->command.digest)||strcmp(session->rom.sha256,game->command.digest)||strcmp(game->rom.sha256,game->command.digest)||memcmp(session->token,runtime->request.session,16)||session->epoch!=runtime->request.epoch){errno=EINVAL;return -1;}
 /* Authenticate power and the bound RESET source before seeding or spawning.
  * A partial input record or a pending manager RESET refuses this attempt.
  * The owner must continue observing the sources immediately after spawn. */
 if(!entry->control||entry->control->save!=&session->save||entry->control->reset!=entry->reset||entry->control->power!=entry->power||
    entry->control->started||entry->control->failed||entry->control->finished||entry->control->reason!=HC_STOCK_CONTROL_NONE||
    entry->control->exit_owner.phase||entry->control->exit_owner.save||entry->control->exit_owner.deadline||entry->control->exit_owner.last||
    entry->control->exit_owner.timed_out||entry->control->exit_owner.kill_sent||session->save.phase!=HC_STOCK_PREPARED||
    !entry->power||(entry->manager_mode!=0&&entry->manager_mode!=1)||entry->manager_mode!=entry->control->manager_mode||entry->manager_probe!=entry->control->manager_probe||
    (entry->manager_mode?entry->reset!=NULL:(!entry->reset||entry->reset->fd!=entry->reset_fd||entry->reset->key!=entry->reset_key||entry->reset->fd==entry->power->fd||!input_ready(entry->reset->fd)||entry->reset->failed))||
    entry->power->fd!=entry->power_fd||entry->power->type!=entry->power_type||entry->power->code!=entry->power_code||entry->power->value!=entry->power_value||!input_ready(entry->power->fd)||entry->power->failed){errno=EINVAL;return -1;}
 int reset=entry->reset?hc_stock_reset_poll(entry->reset):entry->manager_probe?entry->manager_probe():-1,power=hc_stock_power_poll(entry->power);
 if(reset!=0||power!=0||entry->control->manager_reset||(entry->reset&&(entry->reset->used||entry->reset->pressed))||entry->power->used||entry->power->triggered){errno=EBUSY;return -1;}
 if(hc_stock_screenshot_signal_ready(entry->control))return -1;
 if((autoload&&target!=210)||hc_stock_game_autoload_ready(session,autoload))return -1;
 /* Once handed off, no second attempt can reuse a possibly seeded session. */
 entry->ready=0;
 int result=hc_stock_game_start_seeded_reviewed(session,target,program,program_path,core,core_path,config,config_path,autoload,envp);
#ifdef HC_TEST_POSTSPAWN_FAILURE
 extern int hc_test_postspawn_failure(void);
 if(!result&&hc_test_postspawn_failure()){errno=EIO;result=-1;}
#endif
 entry->start_failed=result!=0;
 if(result&&session->save.phase==HC_STOCK_RUNNING&&session->save.child.pid>1){
  /* A failure after fork still owns a child. Request a graceful abort through
   * the already-bound control owner, then leave the owner alive for polling. */
  int saved=errno;struct timespec t;
  if(!clock_gettime(CLOCK_MONOTONIC,&t)&&t.tv_sec>=0&&t.tv_nsec>=0&&t.tv_nsec<1000000000L&&
     (uint64_t)t.tv_sec<=(UINT64_MAX-999)/1000){
   uint64_t now=(uint64_t)t.tv_sec*1000+(uint64_t)t.tv_nsec/1000000;
   (void)hc_stock_control_abort(entry->control,now);
  }
  errno=saved;
 }
 return result;
}
