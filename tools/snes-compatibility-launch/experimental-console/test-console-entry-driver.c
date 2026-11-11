#define _POSIX_C_SOURCE 200809L
#include "console-game.h"
#include "stock-game-session.h"
#include "stock-runtime-bridge.h"
#include "startup-status.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <stdio.h>
/* Host-only test driver. Paths and peers below are isolated fixtures, not an
 * authentication or release implementation for the console. */
int hc_test_entry_run(HCConsoleGame *game,int argc,const char *const argv[],int object_fd){
 const char *root=getenv("HC_ENTRY_ROOT"),*program=getenv("HC_ENTRY_CHILD");assert(root&&program);
 const char *expected_save=getenv("HC_EXPECT_MANAGER_SAVE"),*expected_image=getenv("HC_EXPECT_MANAGER_IMAGE");
 if(expected_save||expected_image){assert(expected_save&&expected_image&&game->command.checkpoint.have_save&&game->command.checkpoint.have_image);assert(!strcmp(game->command.checkpoint.save,expected_save)&&!strcmp(game->command.checkpoint.image,expected_image));}
 char objects[512],profiles[512],core[512];assert(snprintf(objects,sizeof objects,"%s/objects",root)>0);assert(snprintf(profiles,sizeof profiles,"%s/profiles",root)>0);assert(snprintf(core,sizeof core,"%s/core.so",root)>0);
 int parent=open(root,O_RDONLY|O_DIRECTORY|O_CLOEXEC);assert(parent>=0);
 /* Prepare the target-style session from an empty profiles root. */
 char fresh[1024];assert(snprintf(fresh,sizeof fresh,"%s/fresh-profiles",root)>0&&!mkdir(fresh,0700));
 HCGameSavePaths fresh_paths;assert(!hc_launch_isolated_save_paths_at_root(argc-4,argv+4,game->command.game,game->command.digest,fresh,&fresh_paths));
 HCConsoleStartSpec fresh_spec={0};fresh_spec.uid=geteuid();fresh_spec.game=game->command.game;fresh_spec.digest=game->command.digest;fresh_spec.rom_name=game->command.rom_name;fresh_spec.verified_rom=&game->rom;fresh_spec.profiles_root=fresh;fresh_spec.manager_argc=argc-4;fresh_spec.manager_argv=argv+4;fresh_spec.expected_sram=fresh_paths.sram;fresh_spec.expected_rtc=fresh_paths.rtc;
 HCConsoleRuntime fresh_runtime=HC_CONSOLE_RUNTIME_INITIALIZER;HCConsoleSupervisor fresh_supervisor=HC_CONSOLE_SUPERVISOR_INITIALIZER;
 assert(!hc_console_runtime_prepare_game(&fresh_runtime,&fresh_spec));
 assert(fresh_runtime.save_lock>=3&&fresh_runtime.workspace>=3);
 HCConsoleRuntime blocked_runtime=HC_CONSOLE_RUNTIME_INITIALIZER;
 assert(hc_console_runtime_prepare_game(&blocked_runtime,&fresh_spec)<0&&blocked_runtime.workspace==-1&&blocked_runtime.save_lock==-1);
 assert(!hc_console_runtime_close(&blocked_runtime,NULL));
 int fresh_sessions=openat(fresh_runtime.save_lock,"sessions",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);assert(fresh_sessions>=3);
 assert(!hc_console_runtime_discard_unstarted(&fresh_runtime,fresh_sessions,&fresh_supervisor));
 /* A prior crash before manager metadata is durable leaves an incomplete
  * workspace. Do not create another session until it is reconciled. */
 const char *unfinished="checkpoint-ffffffffffffffffffffffffffffffff";
 assert(!mkdirat(fresh_sessions,unfinished,0700));
 HCConsoleRuntime interrupted=HC_CONSOLE_RUNTIME_INITIALIZER;
 assert(hc_console_runtime_prepare_game(&interrupted,&fresh_spec)<0&&interrupted.workspace==-1&&interrupted.save_lock==-1);
 assert(!hc_console_runtime_close(&interrupted,NULL));
 assert(!unlinkat(fresh_sessions,unfinished,AT_REMOVEDIR));
 /* Build synthetic records through the low-level fixture API. These are not
  * verified completed sessions, so normal gameplay must refuse to reuse them. */
 for(int i=0;i<18;i++){
  HCConsoleRuntime existing=HC_CONSOLE_RUNTIME_INITIALIZER;
  assert(!hc_console_runtime_prepare(&existing,fresh_sessions,geteuid(),game->command.game,game->command.digest));
  assert(!hc_console_game_prepare_manager_record(game,&existing,argc,argv));
  assert(!hc_console_runtime_close(&existing,NULL));
 }
 HCManagerRecordObservation *many=calloc(18,sizeof *many);size_t many_count=0;
 assert(many&&!hc_console_game_inventory_manager_records(fresh_sessions,game->command.game,game->command.digest,many,18,&many_count)&&many_count==18);
 memset(many,0x5a,18*sizeof *many);many_count=37;errno=0;
 assert(hc_console_game_inventory_manager_records(fresh_sessions,game->command.game,game->command.digest,many,17,&many_count)<0&&errno==ENOSPC&&many_count==37);
 for(size_t i=0;i<18*sizeof *many;i++)assert(((unsigned char *)many)[i]==0x5a);
 free(many);
 HCConsoleRuntime unconfirmed=HC_CONSOLE_RUNTIME_INITIALIZER;
 assert(hc_console_runtime_prepare_game(&unconfirmed,&fresh_spec)<0&&errno==EBUSY&&unconfirmed.workspace==-1&&unconfirmed.save_lock==-1);
 assert(!hc_console_runtime_close(&unconfirmed,NULL));
 assert(!mkdirat(fresh_sessions,unfinished,0700));
 HCConsoleRuntime later_interruption=HC_CONSOLE_RUNTIME_INITIALIZER;
 assert(hc_console_runtime_prepare_game(&later_interruption,&fresh_spec)<0&&later_interruption.workspace==-1&&later_interruption.save_lock==-1);
 assert(!hc_console_runtime_close(&later_interruption,NULL)&&!unlinkat(fresh_sessions,unfinished,AT_REMOVEDIR));
 assert(!close(fresh_sessions));
 /* Host-only exercise of the actual console entry's verified game handoff. */
 char savepath[1024],stagepath[512];assert(snprintf(savepath,sizeof savepath,"%s/%s/hakchi/%s/%s",profiles,game->command.game,HC_COMPATIBILITY_ENGINE_ID,game->command.digest)>0);
 assert(snprintf(stagepath,sizeof stagepath,"%s/stage",root)>0);
 int savefd=open(savepath,O_RDONLY|O_DIRECTORY|O_CLOEXEC),stagefd=open(stagepath,O_RDONLY|O_DIRECTORY|O_CLOEXEC);assert(savefd>=0&&stagefd>=0);
 assert(hc_console_runtime_open_session_parent(savefd,geteuid(),0)<0);
 int profilesfd=open(profiles,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);assert(profilesfd>=0);
 assert(hc_console_game_open_persistent_sessions(profilesfd,profiles,geteuid(),game->command.game,game->command.digest)==-2);
 assert(!mkdirat(parent,"unsafe-session-root",0700));int unsafe=openat(parent,"unsafe-session-root",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);assert(unsafe>=0);
 assert(!symlinkat(".",unsafe,"sessions"));assert(hc_console_runtime_open_session_parent(unsafe,geteuid(),1)<0);
 assert(!unlinkat(unsafe,"sessions",0)&&!mkdirat(unsafe,"sessions",0700)&&!fchmodat(unsafe,"sessions",0755,0));assert(hc_console_runtime_open_session_parent(unsafe,geteuid(),1)<0);
 assert(!unlinkat(unsafe,"sessions",AT_REMOVEDIR)&&!close(unsafe)&&!unlinkat(parent,"unsafe-session-root",AT_REMOVEDIR));
 int session_parent=hc_console_runtime_open_session_parent(savefd,geteuid(),1);assert(session_parent>=0);
 int discovered=hc_console_game_open_persistent_sessions(profilesfd,profiles,geteuid(),game->command.game,game->command.digest);assert(discovered>=0);
 struct stat discovered_stat;assert(!fstat(discovered,&discovered_stat));
 assert(hc_console_game_open_persistent_sessions(profilesfd,profiles,geteuid(),"CLV-U-WRONG",game->command.digest)<0);
 assert(!close(profilesfd));
 int reopened=hc_console_runtime_open_session_parent(savefd,geteuid(),0);assert(reopened>=0);
 struct stat first_parent,second_parent;assert(!fstat(session_parent,&first_parent)&&!fstat(reopened,&second_parent)&&first_parent.st_ino==second_parent.st_ino&&first_parent.st_dev==second_parent.st_dev);assert(!close(reopened));
 assert(discovered_stat.st_dev==first_parent.st_dev&&discovered_stat.st_ino==first_parent.st_ino);
 HCConsoleRuntime runtime=HC_CONSOLE_RUNTIME_INITIALIZER;HCConsoleSupervisor supervisor=HC_CONSOLE_SUPERVISOR_INITIALIZER;
 const char *reviewed_input=getenv("HC_ENTRY_REQUEST_INPUT");
 if(reviewed_input&&reviewed_input[0]){
  int f=open(reviewed_input,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);assert(f>=0);unsigned char wire[HC_LAUNCH_REQUEST_SIZE+1];
  ssize_t n=read(f,wire,sizeof wire);assert(n==HC_LAUNCH_REQUEST_SIZE&&!close(f));HCLaunchRequest reviewed;
  assert(!hc_launch_request_decode(wire,(size_t)n,&reviewed));
  assert(!hc_console_runtime_prepare_bound(&runtime,session_parent,geteuid(),&reviewed,game->command.game,game->command.digest));
 }else assert(!hc_console_runtime_prepare(&runtime,session_parent,geteuid(),game->command.game,game->command.digest));
 HCConsoleRuntime next=HC_CONSOLE_RUNTIME_INITIALIZER;HCConsoleSupervisor unused=HC_CONSOLE_SUPERVISOR_INITIALIZER;
 assert(!hc_console_runtime_prepare(&next,session_parent,geteuid(),game->command.game,game->command.digest));
 assert(memcmp(runtime.request.session,next.request.session,16));
 HCConsoleRuntime invalid=HC_CONSOLE_RUNTIME_INITIALIZER;HCStockGameSession invalid_stock=HC_STOCK_GAME_SESSION_INITIALIZER;
 assert(!hc_console_runtime_prepare(&invalid,session_parent,geteuid(),game->command.game,game->command.digest));
 assert(hc_stock_game_prepare_runtime(&invalid_stock,&invalid,game,argc,argv,profiles,savefd,stagefd,"../invalid",32768)<0);
 assert(!invalid.claimed);assert(!hc_stock_game_close(&invalid_stock));
 assert(!hc_console_runtime_discard_unstarted(&invalid,session_parent,&unused));
 HCStockGameSession stock=HC_STOCK_GAME_SESSION_INITIALIZER;
 const int invalid_locks[]={-2,0,1,2};
 for(size_t i=0;i<sizeof invalid_locks/sizeof invalid_locks[0];i++){
  runtime.save_lock=invalid_locks[i];
  assert(hc_stock_game_prepare_runtime(&stock,&runtime,game,argc,argv,profiles,savefd,stagefd,"210.srm",32768)<0);
  assert(!runtime.claimed&&!runtime.stock_claimed&&stock.save_lock==-1&&!stock.rom.ready);
 }
 runtime.save_lock=-1;
 char original=runtime.request.digest[0];runtime.request.digest[0]=original=='a'?'b':'a';
 assert(hc_stock_game_prepare_runtime(&stock,&runtime,game,argc,argv,profiles,savefd,stagefd,"210.srm",32768));
 runtime.request.digest[0]=original;runtime.attempted=1;
 assert(hc_stock_game_prepare_runtime(&stock,&runtime,game,argc,argv,profiles,savefd,stagefd,"210.srm",32768));
 runtime.attempted=0;
 char first=runtime.workspace_name[0];runtime.workspace_name[0]='x';
 assert(hc_stock_game_prepare_runtime(&stock,&runtime,game,argc,argv,profiles,savefd,stagefd,"210.srm",32768));
 runtime.workspace_name[0]=first;
 first=runtime.request.game[6];runtime.request.game[6]=first=='A'?'B':'A';
 assert(hc_stock_game_prepare_runtime(&stock,&runtime,game,argc,argv,profiles,savefd,stagefd,"210.srm",32768));
 runtime.request.game[6]=first;
 assert(!hc_stock_game_prepare_runtime(&stock,&runtime,game,argc,argv,profiles,savefd,stagefd,"210.srm",32768));
 assert(!hc_console_game_check_manager_record(runtime.workspace,&runtime.request,&game->command.checkpoint));
 runtime.request.session[0]^=1;assert(hc_console_game_prepare_manager_record(game,&runtime,argc,argv)<0);runtime.request.session[0]^=1;
 int metafd=openat(runtime.workspace,"manager.meta",O_RDWR|O_NOFOLLOW|O_CLOEXEC);unsigned char marker;
 assert(metafd>=0&&pread(metafd,&marker,1,0)==1&&pwrite(metafd,"X",1,0)==1);
 assert(hc_console_game_prepare_manager_record(game,&runtime,argc,argv)<0);
 assert(pwrite(metafd,&marker,1,0)==1&&!close(metafd));
 assert(!hc_console_game_prepare_manager_record(game,&runtime,argc,argv));
 assert(hc_console_runtime_discard_unstarted(&runtime,session_parent,&supervisor)<0);
 assert(!memcmp(stock.token,runtime.request.session,16)&&stock.epoch==runtime.request.epoch);
 assert(!hc_stock_game_recheck(&stock));assert(!hc_stock_game_close(&stock));assert(!close(savefd)&&!close(stagefd));
 struct sigaction ignore={0};ignore.sa_handler=SIG_IGN;sigemptyset(&ignore.sa_mask);assert(!sigaction(SIGPIPE,&ignore,NULL));
 const char *frontend_sha=getenv("HC_ENTRY_CHILD_SHA");assert(frontend_sha);
 HCVerifiedLaunch frontend=HC_VERIFIED_LAUNCH_INITIALIZER;assert(!hc_verified_rom_open(&frontend,parent,"child",geteuid(),frontend_sha));
 char image_env[1100],save_env[1100];if(expected_image)assert(snprintf(image_env,sizeof image_env,"HC_EXPECT_IMAGE=%s",expected_image)>0);if(expected_save)assert(snprintf(save_env,sizeof save_env,"HC_EXPECT_SAVE=%s",expected_save)>0);
 char *env[3]={NULL,NULL,NULL};int envc=0;if(expected_image)env[envc++]=image_env;if(expected_save)env[envc++]=save_env;HCConsoleStartSpec spec={0};spec.verified_frontend=&frontend;spec.directory=object_fd;spec.uid=geteuid();spec.objects_root=objects;spec.profiles_root=profiles;spec.program=program;spec.envp=env;
 spec.report_target=200;spec.save_target=201;spec.image_target=202;spec.startup_target=203;spec.exit_target=204;spec.rom_target=205;spec.confirm_target=206;
 int started=hc_console_game_start(game,&runtime,&supervisor,argc,argv,&spec,3000,core);
 assert(!started&&supervisor.phase==HC_SUPERVISOR_CONFIRMATION_OBSERVED);
 if(expected_image){
  assert(!hc_console_game_check_manager_record(runtime.workspace,&runtime.request,&game->command.checkpoint));
  int profiles_again=open(profiles,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);assert(profiles_again>=0);
  HCManagerCheckpointPaths session_paths={0},empty_paths={0};HCLaunchRequest bad_session=runtime.request;bad_session.session[0]^=1;
  assert(hc_console_game_read_session_manager(profiles_again,profiles,geteuid(),&bad_session,&session_paths)<0&&!memcmp(&session_paths,&empty_paths,sizeof session_paths));
  bad_session=runtime.request;bad_session.epoch++;
  assert(hc_console_game_read_session_manager(profiles_again,profiles,geteuid(),&bad_session,&session_paths)<0&&!memcmp(&session_paths,&empty_paths,sizeof session_paths));
  assert(hc_console_game_read_session_manager(profiles_again,"/tmp",geteuid(),&runtime.request,&session_paths)<0&&!memcmp(&session_paths,&empty_paths,sizeof session_paths));
  assert(!hc_console_game_read_session_manager(profiles_again,profiles,geteuid(),&runtime.request,&session_paths));
  assert(session_paths.have_image==1&&session_paths.have_save==game->command.checkpoint.have_save&&!strcmp(session_paths.image,game->command.checkpoint.image)&&!strcmp(session_paths.save,game->command.checkpoint.save));
  extern int hc_test_frontend_manager_handoff(const char *,const char *,const char *,const char *,const char *,const HCLaunchRequest *,const HCManagerCheckpointPaths *);
  assert(!hc_test_frontend_manager_handoff(root,profiles,objects,program,frontend_sha,&runtime.request,&game->command.checkpoint));
  /* Exercise the real frontend session lookup with screenshot and time paths
   * together. The separate workspace exists only in this host fixture. */
  const char *extended_args[64];assert(argc+4<64);for(int i=0;i<argc;i++)extended_args[i]=argv[i];
  extended_args[argc]="--load-time-path";extended_args[argc+1]="/var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint0/old.time";
  extended_args[argc+2]="--save-time-path";extended_args[argc+3]="/var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint0/state.time";
  HCConsoleGame extended=*game;assert(!hc_parse_compatibility_menu_command(argc+4,extended_args,&extended.command));
  const char *extended_name="checkpoint-07070707070707070707070707070707";assert(!mkdirat(session_parent,extended_name,0700));
  int extended_dir=openat(session_parent,extended_name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);assert(extended_dir>=0);
  HCConsoleRuntime extended_runtime=HC_CONSOLE_RUNTIME_INITIALIZER;extended_runtime.workspace=extended_dir;extended_runtime.request=runtime.request;memset(extended_runtime.request.session,7,16);
  assert(!hc_console_game_prepare_manager_record(&extended,&extended_runtime,argc+4,extended_args));
  extern int hc_test_frontend_manager_time_handoff(const char *,const HCLaunchRequest *,const HCManagerCheckpointPaths *,const HCManagerTimePaths *);
  assert(!hc_test_frontend_manager_time_handoff(profiles,&extended_runtime.request,&extended.command.checkpoint,&extended.command.time));
  assert(!unlinkat(extended_dir,"manager.meta",0)&&!close(extended_dir)&&!unlinkat(session_parent,extended_name,AT_REMOVEDIR));
  assert(!close(profiles_again));
  HCLaunchRequest observed={0};HCManagerCheckpointPaths observed_paths={0};
  assert(!hc_console_game_observe_manager_record(runtime.workspace,runtime.request.game,runtime.request.digest,&observed,&observed_paths));
  HCManagerRecordObservation inventory[2]={{0}};size_t inventory_count=99;
  /* The separately prepared workspace is reported as incomplete, never hidden. */
  assert(!hc_console_game_inventory_manager_records(session_parent,runtime.request.game,runtime.request.digest,inventory,2,&inventory_count));
  assert(inventory_count==2);
  int incomplete=0,complete=0;for(size_t i=0;i<inventory_count;i++){
   if(!strcmp(inventory[i].workspace,next.workspace_name)){assert(inventory[i].status==HC_MANAGER_RECORD_INCOMPLETE);incomplete++;}
   if(!strcmp(inventory[i].workspace,runtime.workspace_name)){assert(inventory[i].status==HC_MANAGER_RECORD_PRESENT);complete++;}
  }assert(incomplete==1&&complete==1);
  int unfinished=openat(session_parent,next.workspace_name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);assert(unfinished>=0);
  assert(hc_console_runtime_discard_unstarted(&next,parent,&unused)<0);
  assert(pwrite(next.save,"X",1,0)==1);assert(hc_console_runtime_discard_unstarted(&next,session_parent,&unused)<0);
  assert(!ftruncate(next.save,0));
  int keep=openat(unfinished,"keep",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);assert(keep>=0&&!close(keep));
  assert(hc_console_runtime_discard_unstarted(&next,session_parent,&unused)<0);
  assert(!unlinkat(unfinished,"keep",0)&&!close(unfinished));
  assert(!hc_console_runtime_discard_unstarted(&next,session_parent,&unused));
  struct stat gone;assert(fstatat(session_parent,next.workspace_name,&gone,AT_SYMLINK_NOFOLLOW)<0&&errno==ENOENT);
  assert(!hc_console_game_inventory_manager_records(discovered,runtime.request.game,runtime.request.digest,inventory,2,&inventory_count));
  assert(inventory_count==1&&!strcmp(inventory[0].workspace,runtime.workspace_name));
  assert(!memcmp(&inventory[0].request,&runtime.request,sizeof runtime.request));
  assert(!symlinkat(runtime.workspace_name,session_parent,"checkpoint-ffffffffffffffffffffffffffffffff"));
  inventory_count=99;
  assert(hc_console_game_inventory_manager_records(session_parent,runtime.request.game,runtime.request.digest,inventory,2,&inventory_count)<0&&inventory_count==99);
  assert(!unlinkat(session_parent,"checkpoint-ffffffffffffffffffffffffffffffff",0));
  inventory_count=99;
  assert(hc_console_game_inventory_manager_records(session_parent,runtime.request.game,runtime.request.digest,inventory,0,&inventory_count)<0&&inventory_count==99);
  assert(!memcmp(&observed,&runtime.request,sizeof observed));
  assert(observed_paths.have_save==game->command.checkpoint.have_save&&observed_paths.have_image==1);
  assert(!strcmp(observed_paths.save,game->command.checkpoint.save)&&!strcmp(observed_paths.image,game->command.checkpoint.image));
  HCLaunchRequest unchanged=observed;HCManagerCheckpointPaths paths_unchanged=observed_paths;
  unsigned char bounded[16];memset(bounded,0x5a,sizeof bounded);size_t bounded_length=42;
  assert(hc_console_game_export_manager_record(runtime.workspace,runtime.request.game,runtime.request.digest,bounded,sizeof bounded,&bounded_length)<0);
  assert(bounded_length==42);for(size_t i=0;i<sizeof bounded;i++)assert(bounded[i]==0x5a);
  assert(hc_console_game_observe_manager_record(runtime.workspace,"CLV-U-WRONG",runtime.request.digest,&observed,&observed_paths)<0);
  assert(hc_console_game_observe_manager_record(runtime.workspace,runtime.request.game,"0000000000000000000000000000000000000000000000000000000000000000",&observed,&observed_paths)<0);
  assert(!memcmp(&unchanged,&observed,sizeof observed)&&!memcmp(&paths_unchanged,&observed_paths,sizeof observed_paths));
  assert(hc_console_game_start(game,&runtime,&supervisor,argc,argv,&spec,3000,core)<0);
  assert(!hc_console_game_check_manager_record(runtime.workspace,&runtime.request,&game->command.checkpoint));
  HCLaunchRequest wrong=runtime.request;wrong.session[0]^=1;
  assert(hc_console_game_check_manager_record(runtime.workspace,&wrong,&game->command.checkpoint)<0);
  HCManagerCheckpointPaths different=game->command.checkpoint;different.image[strlen(different.image)-5]^=1;
  assert(hc_console_game_check_manager_record(runtime.workspace,&runtime.request,&different)<0);
  int record=openat(runtime.workspace,"manager.meta",O_RDWR|O_NOFOLLOW|O_CLOEXEC);assert(record>=0);
  unsigned char original;assert(pread(record,&original,1,120)==1);unsigned char altered=original^1;assert(pwrite(record,&altered,1,120)==1);
  assert(hc_console_game_check_manager_record(runtime.workspace,&runtime.request,&game->command.checkpoint)<0);
  assert(hc_console_game_observe_manager_record(runtime.workspace,runtime.request.game,runtime.request.digest,&observed,&observed_paths)<0);
  assert(pwrite(record,&original,1,120)==1&&!close(record));
  assert(!renameat(runtime.workspace,"manager.meta",runtime.workspace,"saved.meta"));assert(!symlinkat("saved.meta",runtime.workspace,"manager.meta"));
  assert(hc_console_game_check_manager_record(runtime.workspace,&runtime.request,&game->command.checkpoint)<0);
  assert(hc_console_game_observe_manager_record(runtime.workspace,runtime.request.game,runtime.request.digest,&observed,&observed_paths)<0);
  profiles_again=open(profiles,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);assert(profiles_again>=0);session_paths=empty_paths;
  assert(hc_console_game_read_session_manager(profiles_again,profiles,geteuid(),&runtime.request,&session_paths)<0&&!memcmp(&session_paths,&empty_paths,sizeof session_paths));assert(!close(profiles_again));
  assert(!unlinkat(runtime.workspace,"manager.meta",0)&&!renameat(runtime.workspace,"saved.meta",runtime.workspace,"manager.meta"));
  assert(!hc_console_game_check_manager_record(runtime.workspace,&runtime.request,&game->command.checkpoint));
  const char *fixture=getenv("HC_ENTRY_RECORD_OUTPUT");
  if(fixture&&fixture[0]){
   int output=open(fixture,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);assert(output>=0);
   int found=openat(discovered,inventory[0].workspace,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);assert(found>=0);
   unsigned char buf[4096];size_t n=0;assert(!hc_console_game_export_manager_record(found,runtime.request.game,runtime.request.digest,buf,sizeof buf,&n));
   assert(n>0&&n<sizeof buf&&write(output,buf,n)==(ssize_t)n);
   assert(!close(found)&&!close(output));
  }
 }
 assert(!hc_child_signal(&supervisor.child,SIGTERM));int status=0,done=0;struct timespec pause={0,1000000};
 for(int i=0;i<5000&&!done;i++){done=hc_console_supervisor_poll(&supervisor,&status);if(!done)nanosleep(&pause,NULL);}
 assert(done==1&&WIFSIGNALED(status));
 if(expected_image)assert(!hc_console_game_check_manager_record(runtime.workspace,&runtime.request,&game->command.checkpoint));
 assert(!hc_console_supervisor_release(&supervisor));assert(!hc_console_runtime_close(&runtime,&supervisor));assert(!hc_verified_launch_close(&frontend));assert(!close(discovered));assert(!close(session_parent));assert(!close(parent));
 puts("HOST ENTRY HANDOFF VERIFIED; GAMEPLAY DISABLED");return 0;
}
