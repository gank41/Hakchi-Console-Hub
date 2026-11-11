#define _POSIX_C_SOURCE 200809L
#include "stock-gameplay.h"
#include "console-support.h"
#include "stock-screenshot-signal.h"
#include <errno.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#if defined(HC_STOCK_REQUIRE_MANAGER_TRANSITION) && defined(__arm__)
#error "Host-only manager-transition test flag cannot be used on the console"
#endif
#if defined(HC_STOCK_RETAINED_TEST_HOOK) && defined(__arm__)
#error "Retained-image interruption injection is host-only"
#endif
#if defined(HC_STOCK_GAMEPLAY_CLOCK_TEST) && defined(__arm__)
#error "Gameplay clock injection is host-only"
#endif
static int gameplay_clock(HCPlaytimeInstant *out){
#ifdef HC_STOCK_GAMEPLAY_CLOCK_TEST
 extern int hc_test_gameplay_clock(HCPlaytimeInstant *);return hc_test_gameplay_clock(out);
#else
 struct timespec now;if(!out||clock_gettime(CLOCK_MONOTONIC,&now)||now.tv_sec<0||now.tv_nsec<0||now.tv_nsec>=1000000000L){errno=EIO;return -1;}
 *out=(HCPlaytimeInstant){(uint64_t)now.tv_sec,(uint32_t)now.tv_nsec};return 0;
#endif
}
static int image_time_only(const HCCompatibilityMenuCommand *command);
static int image_resumed_time_only(const HCCompatibilityMenuCommand *command);
static int manager_request_valid(const HCStockEntryLaunch *e){
 if(!e||!e->game||!e->runtime||e->runtime->workspace<3||
    !hc_stock_entry_command_manager_outputs(&e->game->command)||
    hc_console_game_check_manager_record_full(e->runtime->workspace,&e->runtime->request,&e->game->command.checkpoint,&e->game->command.time)){errno=EINVAL;return -1;}
 return 0;
}
static int prepare(HCStockGameplay *g,HCStockEntryLaunch *e,int manager_outputs){
 if(!g||g->phase!=HC_GAMEPLAY_EMPTY||g->entry||g->session||g->control||g->support||g->transition||g->retained_image||g->image_capture||g->time_seed||g->state_capture||g->state_archive||g->state_package||g->manager_state||g->manager_state_parent!=-1||g->selected_state||g->clock_enabled||g->clock_started||g->clock_stopped||!e||!e->ready||!e->session||!e->runtime||!e->game||!e->control||e->control->save!=&e->session->save||e->control->transition||e->control->started||e->control->failed||e->control->finished||e->start_failed||e->session->save.phase!=HC_STOCK_PREPARED||e->session->save.child.pid!=-1||e->session->save.child.reaped_pending||e->session->save.child_wait_unknown){errno=EINVAL;return -1;}
 /* The default route remains battery-only. The explicit experimental route
  * accepts only the output combination its owner can finalize. */
 if(g->manager_outputs||(!manager_outputs&&!hc_stock_entry_command_supported(&e->game->command))||
    (manager_outputs&&manager_request_valid(e))){errno=ENOTSUP;return -1;}
 if(hc_stock_previous_capture(&g->previous,e->session))return -1;
 g->entry=e;g->session=e->session;g->control=e->control;g->phase=HC_GAMEPLAY_PREPARED;
 if(manager_outputs){g->manager_outputs=1;memcpy(&g->manager_original,&e->game->command,sizeof g->manager_original);}
 return 0;
}
int hc_stock_gameplay_prepare(HCStockGameplay *g,HCStockEntryLaunch *e){return prepare(g,e,0);}
int hc_stock_gameplay_prepare_manager_outputs(HCStockGameplay *g,HCStockEntryLaunch *e){return prepare(g,e,1);}
/* Validate every manager descriptor before consuming the wait event. The
 * checked temporary does not mutate the caller's transition or the eventfds. */
static int transition_descriptors_valid(const HCTransition *t){
 HCTransition checked;
 return t && hc_transition_init(&checked,t->wait,t->start,t->finish)==0;
}
static int transition_matches(HCStockGameplay *g,HCTransition *t){
 const unsigned needed=(1u<<HC_WAIT)|(1u<<HC_START)|(1u<<HC_FINISH);
 return g&&g->phase==HC_GAMEPLAY_PREPARED&&g->entry&&g->entry->game&&g->control&&!g->control->transition&&
    t&&t->phase==HC_INITIAL&&(g->entry->game->command.manager.present&needed)==needed&&
    t->wait==g->entry->game->command.manager.wait_fd&&t->start==g->entry->game->command.manager.start_fd&&t->finish==g->entry->game->command.manager.finish_fd&&
    transition_descriptors_valid(t);
}
int hc_stock_gameplay_bind_transition(HCStockGameplay *g,HCTransition *t){
 if(!g||g->transition||!transition_matches(g,t)){errno=EINVAL;return -1;}
 g->transition=t;return 0;
}
int hc_stock_gameplay_bind_retained_image(HCStockGameplay *g,HCStockRetainedImage *retained,HCStockScreenshotReceipt *capture){
 if(!g||g->phase!=HC_GAMEPLAY_PREPARED||g->retained_image||g->image_capture||!g->session||
    !g->control||!g->control->screenshot||g->control->screenshot->context!=capture||!capture||capture->game!=g->session||capture->phase!=1||
    !retained||retained->attempted||retained->published||retained->target.ready){errno=EINVAL;return -1;}
 g->retained_image=retained;g->image_capture=capture;return 0;
}
int hc_stock_gameplay_bind_state_archive(HCStockGameplay *g,HCStockStateReceipt *state,HCStockStateArchive *archive){
 if(!g||g->phase!=HC_GAMEPLAY_PREPARED||g->state_capture||g->state_archive||!g->session||!g->control||!g->control->state||
    !state||g->control->state->context!=state||state->game!=g->session||state->phase!=1||
    !archive||archive->attempted||archive->published||archive->parent!=-1||archive->target.ready){errno=EINVAL;return -1;}
 g->state_capture=state;g->state_archive=archive;return 0;
}
int hc_stock_gameplay_bind_state_package(HCStockGameplay *g,HCStateBytes *out){
 if(!g||g->phase!=HC_GAMEPLAY_PREPARED||!g->state_capture||!g->state_archive||g->state_package||!out||out->data||out->length){errno=EINVAL;return -1;}
 g->state_package=out;return 0;
}
int hc_stock_gameplay_bind_manager_state(HCStockGameplay *g,HCStockManagerState *out,int parent){
 if(!g||g->phase!=HC_GAMEPLAY_PREPARED||!g->manager_outputs||!g->entry||!g->state_archive||!g->state_package||g->manager_state||g->manager_state_parent!=-1||
    hc_stock_manager_state_preflight(out,g->session,g->entry->runtime,g->entry->game,parent)){errno=EINVAL;return -1;}
 g->manager_state=out;g->manager_state_parent=parent;return 0;
}
int hc_stock_gameplay_bind_selected_state(HCStockGameplay *g,HCStockSelectedState *selected){
 if(!g||g->phase!=HC_GAMEPLAY_PREPARED||!g->manager_outputs||!g->entry||g->selected_state||!selected||selected->game!=g->session||
    selected->runtime!=g->entry->runtime||selected->menu!=g->entry->game||hc_stock_selected_state_recheck(selected)){errno=EINVAL;return -1;}
 g->selected_state=selected;return 0;
}
int hc_stock_gameplay_enable_time(HCStockGameplay *g){
 if(!g||g->phase!=HC_GAMEPLAY_PREPARED||g->clock_enabled||g->clock_started||g->clock_stopped){errno=EINVAL;return -1;}
 g->clock_enabled=1;return 0;
}
static int gameplay_seed_matches(HCStockGameplay *g,HCStockTimeSeed *seed){
 if(!g||!seed||!g->entry||!g->entry->game||!g->entry->runtime||seed->session!=g->session||!seed->runtime||!seed->menu||
    memcmp(seed->game,g->entry->game->command.game,sizeof seed->game)||memcmp(seed->digest,g->entry->game->command.digest,sizeof seed->digest)||
    memcmp(seed->game,g->entry->runtime->request.game,sizeof seed->game)||memcmp(seed->digest,g->entry->runtime->request.digest,sizeof seed->digest)||
    memcmp(seed->token,g->entry->runtime->request.session,16)||seed->epoch!=g->entry->runtime->request.epoch||
    hc_stock_time_seed_recheck(seed,g->session,seed->runtime,seed->menu,seed->parent)||
    (seed->backup_attempted&&hc_stock_time_seed_backup_recheck(seed,g->session,seed->backup_runtime))){errno=EINVAL;return -1;}
 return 0;
}
int hc_stock_gameplay_bind_time_seed(HCStockGameplay *g,HCStockTimeSeed *seed){
 if(!g||g->phase!=HC_GAMEPLAY_PREPARED||!g->clock_enabled||g->time_seed||gameplay_seed_matches(g,seed)||
    (g->manager_outputs&&(seed->runtime!=g->entry->runtime||seed->menu!=g->entry->game))){errno=EINVAL;return -1;}
 g->time_seed=seed;
 if(hc_stock_time_seed_retain(seed,g->session,g->entry->runtime)){g->phase=HC_GAMEPLAY_RECOVERY;return -1;}
 return 0;
}
/* A single-threaded session owns the support holder until finalization or a
 * confirmed pre-launch/aborted failure. Recovery retains it on uncertainty. */
static int release_support(HCStockGameplay *g){
 if(!g->support)return 0;
 if(g->support->borrower!=g){errno=EINVAL;return -1;}
 g->support->borrower=NULL;g->support=NULL;return 0;
}
int hc_stock_gameplay_start(HCStockGameplay *g,const HCStockLaunchSpec *s){
 if(!g||g->phase!=HC_GAMEPLAY_PREPARED||g->support||!s||!g->entry||g->entry->session!=g->session||g->entry->control!=g->control){errno=EINVAL;return -1;}
 if((g->state_package&&(!g->state_archive||g->state_package->data||g->state_package->length))||(!!g->state_capture!=!!g->state_archive)||(g->state_capture&&(!g->control->state||g->control->state->context!=g->state_capture||
    g->state_capture->game!=g->session||g->state_capture->phase!=1||g->state_archive->attempted||g->state_archive->target.ready))){errno=EINVAL;return -1;}
 if(!g->manager_outputs&&(!g->entry->game||!hc_stock_entry_command_supported(&g->entry->game->command))){errno=ENOTSUP;return -1;}
 if(g->manager_outputs&&(!g->entry->game||memcmp(&g->manager_original,&g->entry->game->command,sizeof g->manager_original)||
    manager_request_valid(g->entry)||!g->transition||!g->clock_enabled||!g->retained_image||!g->image_capture||
    !g->control->screenshot||g->control->screenshot->context!=g->image_capture||
    g->image_capture->game!=g->session||g->image_capture->phase!=1||g->retained_image->attempted||
    g->retained_image->published||g->retained_image->target.ready||
    (!!g->entry->game->command.time.have_load!=!!g->time_seed))){errno=EINVAL;return -1;}
 if(g->manager_outputs&&((!!g->entry->game->command.checkpoint.have_save!=!!g->manager_state)||
    (g->manager_state&&(!g->state_package||hc_stock_manager_state_preflight(g->manager_state,g->session,g->entry->runtime,g->entry->game,g->manager_state_parent))))){errno=EINVAL;return -1;}
 if(g->manager_outputs&&((!!g->entry->game->command.checkpoint.have_load!=!!g->selected_state)||
    (!!g->entry->game->command.checkpoint.have_load!=!!s->autoload)||
    (g->selected_state&&hc_stock_selected_state_recheck(g->selected_state)))){errno=EINVAL;return -1;}
 if((s->autoload&&s->target!=210)||hc_stock_game_autoload_ready(g->session,s->autoload))return -1;
 if(hc_stock_screenshot_signal_ready(g->control))return -1;
 if(g->time_seed&&gameplay_seed_matches(g,g->time_seed))return -1;
 /* On the console, only the held and rechecked support bundle can supply
  * executable and core. The owner retains it until the child has exited. */
 if(g->transition&&!transition_matches(g,g->transition)){errno=EINVAL;return -1;}
#if defined(__arm__) || defined(HC_STOCK_REQUIRE_CONSOLE_SUPPORT)
 if(!s->support){errno=EINVAL;return -1;}
#endif
#if defined(__arm__) || defined(HC_STOCK_REQUIRE_MANAGER_TRANSITION)
 if(!g->transition){errno=EINVAL;return -1;}
#endif
 if(s->support){
  if(s->support->borrower){errno=EBUSY;return -1;}
  if(hc_console_support_matches_launch(s->support,s->program,s->program_path,s->core,s->core_path))return -1;
  s->support->borrower=g;g->support=s->support;
 }
 /* This waits before spawning, which ensures no early emulator frame. The
  * installed manager's timing for this path is not yet hardware-verified. */
 if(g->transition&&(hc_transition_before_first_frame(g->transition)||hc_stock_control_attach_transition(g->control,g->transition))){g->phase=HC_GAMEPLAY_RECOVERY;return -1;}
 if(g->selected_state&&hc_stock_selected_state_recheck(g->selected_state)){g->phase=HC_GAMEPLAY_RECOVERY;return -1;}
 if(g->clock_enabled){
  if(g->clock_started||g->clock_stopped||gameplay_clock(&g->clock_start)){g->phase=HC_GAMEPLAY_RECOVERY;return -1;}
  g->clock_started=1;
 }
 HCStockEntryLaunch *e=g->entry;
 int r=hc_stock_entry_start(e,g->session,e->runtime,e->game,s->target,s->program,s->program_path,s->core,s->core_path,s->config,s->config_path,s->autoload,s->envp);
 if(r){HCStockSaveSession *save=&g->session->save;int saved=errno;g->phase=(save->child_wait_unknown||save->child.reaped_pending||save->child.pid< -1||save->child.pid==0||save->child.pid==1)?HC_GAMEPLAY_RECOVERY:save->child.pid>1?HC_GAMEPLAY_ABORTING:HC_GAMEPLAY_FAILED;
  /* Once the manager wait is consumed, a failed pre-spawn handoff needs
   * explicit recovery; do not invent a completion signal. */
  if(g->phase==HC_GAMEPLAY_FAILED&&g->transition)g->phase=HC_GAMEPLAY_RECOVERY;
  if(g->phase==HC_GAMEPLAY_FAILED&&release_support(g))g->phase=HC_GAMEPLAY_RECOVERY;
  errno=saved;return -1;}
 g->phase=HC_GAMEPLAY_ACTIVE;return 0;
}
int hc_stock_gameplay_poll(HCStockGameplay *g,uint64_t now,int *status){
 if(!g||!status||!g->entry||!g->session||!g->control||g->entry->session!=g->session||g->entry->control!=g->control){errno=EINVAL;return -1;}
 if(g->phase==HC_GAMEPLAY_ABORTING){int r=hc_stock_entry_failed_start_poll(g->entry,now,status);if(!r)return 0;g->phase=r==1?HC_GAMEPLAY_FAILED:HC_GAMEPLAY_RECOVERY;
  if(g->phase==HC_GAMEPLAY_FAILED&&g->transition&&
     (g->control->transition!=g->transition||g->transition->phase!=HC_EXITING||hc_transition_finish_exit(g->transition)))g->phase=HC_GAMEPLAY_RECOVERY;
  if(g->phase==HC_GAMEPLAY_FAILED&&release_support(g))g->phase=HC_GAMEPLAY_RECOVERY;
  errno=EIO;return -1;}
 if(g->phase!=HC_GAMEPLAY_ACTIVE){errno=EINVAL;return -1;}
 int r=hc_stock_control_step(g->control,now,status);if(!r)return 0;
 if(r==1){
  if(g->clock_enabled){
   if(!g->clock_started||g->clock_stopped||gameplay_clock(&g->clock_end)||g->clock_end.seconds<g->clock_start.seconds||
      (g->clock_end.seconds==g->clock_start.seconds&&g->clock_end.nanoseconds<g->clock_start.nanoseconds)){g->phase=HC_GAMEPLAY_RECOVERY;errno=EIO;return -1;}
   g->clock_stopped=1;
  }
  g->phase=HC_GAMEPLAY_STOPPED;return 1;
 }
 g->phase=HC_GAMEPLAY_RECOVERY;return -1;
}
static int image_only(const HCCompatibilityMenuCommand *command){
 if(!command||!command->checkpoint.have_image||!(command->manager.present&(1u<<HC_SCREENSHOT)))return 0;
 HCCompatibilityMenuCommand copy=*command;copy.checkpoint.have_image=0;copy.manager.present&=~(1u<<HC_SCREENSHOT);
 return hc_stock_entry_command_supported(&copy);
}
static int image_time_only(const HCCompatibilityMenuCommand *command){
 if(!command||!command->time.have_save||command->time.have_load||!(command->manager.present&(1u<<HC_SAVE_TIME)))return 0;
 HCCompatibilityMenuCommand copy=*command;copy.time.have_save=0;copy.manager.present&=~(1u<<HC_SAVE_TIME);
 return image_only(&copy);
}
static int image_time_state_only(const HCCompatibilityMenuCommand *command){
 if(!command||!command->checkpoint.have_save||!(command->manager.present&(1u<<HC_ROLLBACK_OUT)))return 0;
 HCCompatibilityMenuCommand copy=*command;copy.checkpoint.have_save=0;copy.manager.present&=~(1u<<HC_ROLLBACK_OUT);
 if(copy.checkpoint.have_load){if(!(copy.manager.present&(1u<<HC_ROLLBACK_IN)))return 0;copy.checkpoint.have_load=0;copy.manager.present&=~(1u<<HC_ROLLBACK_IN);}
 return image_time_only(&copy);
}
static int image_resumed_time_only(const HCCompatibilityMenuCommand *command){
 if(!command||!command->time.have_load||!(command->manager.present&(1u<<HC_LOAD_TIME)))return 0;
 HCCompatibilityMenuCommand copy=*command;copy.time.have_load=0;copy.manager.present&=~(1u<<HC_LOAD_TIME);
 return image_time_only(&copy);
}
static int image_resumed_time_state_only(const HCCompatibilityMenuCommand *command){
 if(!command||!command->checkpoint.have_save||!(command->manager.present&(1u<<HC_ROLLBACK_OUT)))return 0;
 HCCompatibilityMenuCommand copy=*command;copy.checkpoint.have_save=0;copy.manager.present&=~(1u<<HC_ROLLBACK_OUT);
 if(copy.checkpoint.have_load){if(!(copy.manager.present&(1u<<HC_ROLLBACK_IN)))return 0;copy.checkpoint.have_load=0;copy.manager.present&=~(1u<<HC_ROLLBACK_IN);}
 return image_resumed_time_only(&copy);
}
static int finish(HCStockGameplay *g,HCStockManagerImage *image,HCStockManagerTime *time,HCStockTimeSeed *seed,int manager_parent,HCPlaytimeInstant start,HCPlaytimeInstant end){
 if(!g||g->phase!=HC_GAMEPLAY_STOPPED||!g->session||!g->control||!g->entry||g->entry->session!=g->session||g->entry->control!=g->control){errno=EINVAL;return -1;}
 if(g->time_seed!=seed){errno=EINVAL;return -1;}
 if(!g->entry->game||!g->entry->runtime){errno=EINVAL;return -1;}
 if(g->manager_outputs&&(!!g->entry->game->command.checkpoint.have_load!=!!g->selected_state)){g->phase=HC_GAMEPLAY_RECOVERY;errno=EINVAL;return -1;}
 if(g->manager_outputs&&(memcmp(&g->manager_original,&g->entry->game->command,sizeof g->manager_original)||manager_request_valid(g->entry))){g->phase=HC_GAMEPLAY_RECOVERY;errno=EINVAL;return -1;}
 if(image){
  if(manager_parent<3||!g->transition||!g->retained_image||!g->image_capture||image->attempted||image->published||image->target.ready){errno=EINVAL;return -1;}
  if(g->manager_state){struct stat a,b;if(g->manager_state_parent<3||fstat(manager_parent,&a)||fstat(g->manager_state_parent,&b)||
      (a.st_dev==b.st_dev&&a.st_ino==b.st_ino)){errno=EINVAL;return -1;}}
  if(time){
   if(time->attempted||time->published||time->target.ready||!(seed?(g->manager_state?image_resumed_time_state_only(&g->entry->game->command):image_resumed_time_only(&g->entry->game->command)):g->manager_state?image_time_state_only(&g->entry->game->command):image_time_only(&g->entry->game->command))||
      (seed&&(hc_stock_time_seed_recheck(seed,g->session,g->entry->runtime,g->entry->game,manager_parent)||hc_stock_time_seed_backup_recheck(seed,g->session,seed->backup_runtime)))||start.nanoseconds>=1000000000u||end.nanoseconds>=1000000000u||
      end.seconds<start.seconds||(end.seconds==start.seconds&&end.nanoseconds<start.nanoseconds)){errno=EINVAL;return -1;}
   if(seed){uint64_t elapsed=end.seconds-start.seconds;if(end.nanoseconds<start.nanoseconds)elapsed--;if(seed->prior>UINT64_MAX-elapsed){errno=EOVERFLOW;return -1;}}
  }else if(!image_only(&g->entry->game->command)){errno=EINVAL;return -1;}
 }else if(!hc_stock_entry_command_supported(&g->entry->game->command)){errno=ENOTSUP;return -1;}
 if(g->transition&&(g->control->transition!=g->transition||g->transition->phase!=HC_EXITING)){g->phase=HC_GAMEPLAY_RECOVERY;errno=EIO;return -1;}
 if((!!g->state_capture!=!!g->state_archive)||(g->state_capture&&(!g->control->state||g->control->state->context!=g->state_capture))){errno=EINVAL;return -1;}
 if(g->state_archive){
  if(hc_stock_previous_validate(&g->previous,g->session))return -1;
  int saved=hc_stock_state_archive_capture(g->state_archive,g->state_capture,g->session,g->entry->runtime,g->control);
  if(saved){g->phase=HC_GAMEPLAY_RECOVERY;return saved==-1?-2:saved;}
  if(hc_stock_state_archive_recheck(g->state_archive,g->state_capture,g->session,g->entry->runtime,g->control)){g->phase=HC_GAMEPLAY_RECOVERY;return -2;}
  if(g->state_package){
   if(hc_stock_state_archive_encode(g->state_archive,g->state_capture,g->session,g->entry->runtime,g->control,g->state_package)){g->phase=HC_GAMEPLAY_RECOVERY;return -2;}
#ifdef HC_STOCK_RETAINED_TEST_HOOK
   {extern void hc_test_stock_retained_hook(int);hc_test_stock_retained_hook(3);}
#endif
  }
  if(g->manager_state){
   if(!g->state_package||hc_stock_manager_state_publish(g->manager_state,g->session,g->entry->runtime,g->entry->game,g->control,g->state_capture,g->state_archive,g->state_package,g->manager_state_parent)){g->phase=HC_GAMEPLAY_RECOVERY;return -2;}
#ifdef HC_STOCK_RETAINED_TEST_HOOK
   {extern void hc_test_stock_retained_hook(int);hc_test_stock_retained_hook(4);}
#endif
  }
 }
 int r;
 if(g->retained_image){
  if(!g->image_capture||hc_stock_previous_validate(&g->previous,g->session)){if(g->state_archive&&g->state_archive->attempted)g->phase=HC_GAMEPLAY_RECOVERY;return -1;}
  r=hc_stock_retained_image_prepare(g->retained_image,g->session,g->control,g->image_capture);
#ifdef HC_STOCK_RETAINED_TEST_HOOK
  if(!r){extern void hc_test_stock_retained_hook(int);hc_test_stock_retained_hook(1);}
#endif
  if(!r&&g->session->save.phase==HC_STOCK_REAPED_NO_SRAM)r=hc_stock_retained_image_finish_no_sram(g->retained_image,g->session,g->control,g->image_capture,g->previous.bytes,g->previous.length);
  else if(!r)r=hc_stock_game_publish_after_exit(g->session,g->control);
#ifdef HC_STOCK_RETAINED_TEST_HOOK
  if(!r&&g->session->save.phase==HC_STOCK_PUBLISHED){extern void hc_test_stock_retained_hook(int);hc_test_stock_retained_hook(2);}
#endif
  if(!r&&g->session->save.phase==HC_STOCK_PUBLISHED)r=hc_stock_retained_image_finish_save(g->retained_image,g->session,g->control,g->image_capture,g->previous.bytes,g->previous.length);
  if(r&&g->retained_image->attempted){g->phase=HC_GAMEPLAY_RECOVERY;if(r==-1)r=-2;}
 }else{
  if(g->image_capture){errno=EINVAL;return -1;}
  r=hc_stock_previous_finish(&g->previous,g->session,g->control);
 }
 if(!r&&image){
  r=hc_stock_manager_image_publish(image,g->retained_image,g->session,g->control,g->image_capture,g->entry->runtime,g->entry->game,manager_parent);
  /* Save finalization has already happened. Even a preflight refusal now
   * requires recovery; never notify the manager or retry as a fresh session. */
  if(r){g->phase=HC_GAMEPLAY_RECOVERY;if(r==-1)r=-2;}
 }
 if(!r&&time){
  r=seed?hc_stock_manager_time_publish_resumed(time,image,g->retained_image,g->session,g->control,g->image_capture,g->entry->runtime,g->entry->game,seed,manager_parent,start,end):hc_stock_manager_time_publish(time,image,g->retained_image,g->session,g->control,g->image_capture,g->entry->runtime,g->entry->game,manager_parent,start,end);
  if(r){g->phase=HC_GAMEPLAY_RECOVERY;if(r==-1)r=-2;}
 }
 if(!r){if((g->state_archive&&hc_stock_state_archive_recheck(g->state_archive,g->state_capture,g->session,g->entry->runtime,g->control))||(g->manager_state&&hc_stock_manager_state_recheck(g->manager_state,g->session,g->entry->runtime,g->entry->game,g->control,g->state_capture,g->state_archive,g->state_package,g->manager_state_parent))){g->phase=HC_GAMEPLAY_RECOVERY;return -2;}if(g->transition&&hc_transition_finish_exit(g->transition)){g->phase=HC_GAMEPLAY_RECOVERY;return -1;}if(image&&hc_stock_retained_image_retire(g->retained_image,g->session,g->control,g->image_capture)){g->phase=HC_GAMEPLAY_RECOVERY;return -2;}if(release_support(g)){g->phase=HC_GAMEPLAY_RECOVERY;return -1;}hc_stock_previous_clear(&g->previous);g->phase=HC_GAMEPLAY_FINISHED;}
 else if(r==-2||r==-3||(g->state_archive&&g->state_archive->attempted))g->phase=HC_GAMEPLAY_RECOVERY;
 return r;
}
int hc_stock_gameplay_finish(HCStockGameplay *g){return finish(g,NULL,NULL,NULL,-1,(HCPlaytimeInstant){0,0},(HCPlaytimeInstant){0,0});}
int hc_stock_gameplay_finish_with_image(HCStockGameplay *g,HCStockManagerImage *image,int manager_parent){
 if(!image){errno=EINVAL;return -1;}return finish(g,image,NULL,NULL,manager_parent,(HCPlaytimeInstant){0,0},(HCPlaytimeInstant){0,0});
}
int hc_stock_gameplay_finish_with_image_time(HCStockGameplay *g,HCStockManagerImage *image,HCStockManagerTime *time,int manager_parent){
 if(!g||!image||!time||!g->clock_enabled||!g->clock_started||!g->clock_stopped){errno=EINVAL;return -1;}
 return finish(g,image,time,NULL,manager_parent,g->clock_start,g->clock_end);
}
int hc_stock_gameplay_finish_with_resumed_time(HCStockGameplay *g,HCStockManagerImage *image,HCStockManagerTime *time,HCStockTimeSeed *seed,int manager_parent){
 if(!g||!image||!time||!seed||!g->clock_enabled||!g->clock_started||!g->clock_stopped){errno=EINVAL;return -1;}
 return finish(g,image,time,seed,manager_parent,g->clock_start,g->clock_end);
}
