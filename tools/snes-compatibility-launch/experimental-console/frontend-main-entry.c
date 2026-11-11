#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#include "frontend-main-entry.h"
#include "arguments.h"
#include "console-game.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <string.h>
#include <unistd.h>
int hc_frontend_verify_save_lock(int fd,const char *directory,uid_t uid){
 struct stat held,named;int opened;
 if(fd<3||!directory||directory[0]!='/'){errno=EINVAL;return -1;}
 if(fstat(fd,&held)||!S_ISDIR(held.st_mode)||held.st_uid!=uid||(held.st_mode&0777)!=0700){errno=EINVAL;return -1;}
 opened=open(directory,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(opened<0)return -1;
 int bad=fstat(opened,&named)||held.st_dev!=named.st_dev||held.st_ino!=named.st_ino||flock(fd,LOCK_EX|LOCK_NB);
 int saved=errno;if(close(opened))bad=1;
 if(bad){errno=saved?saved:EIO;return -1;}return 0;
}
static HCVerifiedLaunch verified_core=HC_VERIFIED_LAUNCH_INITIALIZER;
static char expected_core_path[1024];
static const HCFrontendBootstrap *entry_bootstrap;
int hc_frontend_entry_screenshot_requested(void){return entry_bootstrap && entry_bootstrap->ready && entry_bootstrap->manager_paths_ready && entry_bootstrap->manager_paths.have_image;}
int hc_frontend_entry_savestate_requested(void){return entry_bootstrap && entry_bootstrap->ready && entry_bootstrap->manager_paths_ready && entry_bootstrap->manager_paths.have_save;}
const char *hc_frontend_entry_savestate_path(void){return hc_frontend_entry_savestate_requested()?entry_bootstrap->manager_paths.save:NULL;}
int hc_frontend_entry_core_load_path(const char *requested,char *output,size_t capacity){
 char path[64];
 if(!requested||!output||!capacity||!expected_core_path[0]||strcmp(requested,expected_core_path)||!verified_core.ready||hc_verified_launch_recheck(&verified_core)){errno=EINVAL;return -1;}
#ifdef __APPLE__
 int n=snprintf(path,sizeof path,"/dev/fd/%d",verified_core.rom_fd);
#else
 int n=snprintf(path,sizeof path,"/proc/self/fd/%d",verified_core.rom_fd);
#endif
 if(n<=0||(size_t)n>=sizeof path||(size_t)n>=capacity){errno=ENOSPC;return -1;}
 memcpy(output,path,(size_t)n+1);return 0;
}
int hc_frontend_entry_core_ready(void){return verified_core.ready && !hc_verified_launch_recheck(&verified_core);}
int hc_frontend_entry_observe_manager(const HCFrontendBootstrap *boot,const HCFrontendEntryConfig *cfg,HCManagerCheckpointPaths *out){
 HCManagerCheckpointPaths paths={0};unsigned char frame[HC_LAUNCH_REQUEST_SIZE];int profiles=-1,ok=0;
 if(!boot||!boot->ready||!boot->release_available||!cfg||!cfg->profiles_root||cfg->profiles_root[0]!='/'||!out||
    !hc_frontend_entry_core_ready()||hc_launch_request_encode(&boot->release_request,frame)){errno=EINVAL;return -1;}
 profiles=open(cfg->profiles_root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(profiles<0)return -1;
 if(!hc_console_game_read_session_manager(profiles,cfg->profiles_root,geteuid(),&boot->release_request,&paths)&&hc_frontend_entry_core_ready())ok=1;
 {int saved=errno;if(close(profiles))ok=0;if(!ok){errno=saved?saved:EIO;return -1;}*out=paths;return 0;}
}
int hc_frontend_entry_observe_manager_full(const HCFrontendBootstrap *boot,const HCFrontendEntryConfig *cfg,HCManagerCheckpointPaths *out,HCManagerTimePaths *time_out){
 HCManagerCheckpointPaths paths={0};HCManagerTimePaths time={0};unsigned char frame[HC_LAUNCH_REQUEST_SIZE];int profiles=-1,ok=0;
 if(!boot||!boot->ready||!boot->release_available||!cfg||!cfg->profiles_root||cfg->profiles_root[0]!='/'||!out||!time_out||
    !hc_frontend_entry_core_ready()||hc_launch_request_encode(&boot->release_request,frame)){errno=EINVAL;return -1;}
 profiles=open(cfg->profiles_root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(profiles<0)return -1;
 if(!hc_console_game_read_session_manager_full(profiles,cfg->profiles_root,geteuid(),&boot->release_request,&paths,&time)&&hc_frontend_entry_core_ready())ok=1;
 {int saved=errno;if(close(profiles))ok=0;if(!ok){errno=saved?saved:EIO;return -1;}*out=paths;*time_out=time;return 0;}
}
static int hexval(char c){if(c>='0'&&c<='9')return c-'0';if(c>='a'&&c<='f')return c-'a'+10;return -1;}
int hc_frontend_entry_prepare(HCFrontendBootstrap *boot,int *count,char **args,const HCFrontendEntryConfig *cfg){
 HCLaunchRequest request={0};unsigned char wire[HC_LAUNCH_REQUEST_SIZE];char profile[1024],rom[1024],name[69],sram[1024],binding[40],core_path[1024];
 if(!boot||boot->attempted||!count||(*count!=8&&*count!=10&&*count!=12)||!args||!cfg||!cfg->objects_root||!cfg->profiles_root||
    cfg->objects_root[0]!='/'||cfg->profiles_root[0]!='/'||!cfg->core_root||cfg->core_root[0]!='/'||!cfg->core_name||!cfg->core_sha256||verified_core.ready||!cfg->timeout_ms||cfg->timeout_ms>60000){errno=EINVAL;return -1;}
 for(int i=0;i<*count;i++)if(!args[i]){errno=EINVAL;return -1;}
 int with_image=*count>=10&&!strcmp(args[5],"--hc-manager-screenshot"),with_save=*count==12||(*count==10&&!strcmp(args[5],"--hc-manager-save"));
 int core_index=5+2*with_image+2*with_save,save_index=with_image?7:5;
 if(core_index+3!=*count||strcmp(args[1],"-s")||strcmp(args[3],"--hc-session-frame")||(with_image&&strnlen(args[6],1024)>=1024)||(with_save&&(strcmp(args[save_index],"--hc-manager-save")||strnlen(args[save_index+1],1024)>=1024))||strcmp(args[core_index],"-L")||args[core_index+1][0]!='/'||strnlen(args[4],HC_LAUNCH_REQUEST_SIZE*2+1)!=HC_LAUNCH_REQUEST_SIZE*2){errno=EINVAL;return -1;}
 for(size_t i=0;i<sizeof wire;i++){int a=hexval(args[4][2*i]),b=hexval(args[4][2*i+1]);if(a<0||b<0){errno=EINVAL;return -1;}wire[i]=(unsigned char)((a<<4)|b);}
 if(hc_launch_request_decode(wire,sizeof wire,&request))return -1;
 const char *ext=strrchr(args[core_index+2],'.');if(!ext||(strcmp(ext,".sfc")&&strcmp(ext,".smc"))){errno=EINVAL;return -1;}
 int a=snprintf(name,sizeof name,"%s%s",request.digest,ext);
 int b=snprintf(rom,sizeof rom,"%s/%s",cfg->objects_root,name);
 int c=snprintf(profile,sizeof profile,"%s/%s",cfg->profiles_root,request.game);
 int d=snprintf(sram,sizeof sram,"%s/hakchi/%s/%s/battery.srm",profile,HC_COMPATIBILITY_ENGINE_ID,request.digest);
 int e=snprintf(core_path,sizeof core_path,"%s/%s",cfg->core_root,cfg->core_name);
 static const char digits[]="0123456789abcdef";memcpy(binding,"bind-",5);for(size_t i=0;i<16;i++){binding[5+2*i]=digits[request.session[i]>>4];binding[6+2*i]=digits[request.session[i]&15];}binding[37]=0;
 if(a<=0||a>=(int)sizeof name||b<=0||b>=(int)sizeof rom||c<=0||c>=(int)sizeof profile||d<=0||d>=(int)sizeof sram||e<=0||e>=(int)sizeof core_path||strcmp(core_path,args[core_index+1])||strcmp(rom,args[core_index+2])||strcmp(sram,args[2])){errno=EINVAL;return -1;}
 if(cfg->save_lock_fd){
  char save_directory[sizeof sram];memcpy(save_directory,sram,(size_t)d+1);
  char *last=strrchr(save_directory,'/');if(!last){errno=EINVAL;return -1;}*last=0;
  if(hc_frontend_verify_save_lock(cfg->save_lock_fd,save_directory,geteuid()))return -1;
 }
 int core_dir=open(cfg->core_root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(core_dir<0)return -1;
 HCVerifiedLaunch core=HC_VERIFIED_LAUNCH_INITIALIZER;
 int core_bad=hc_verified_rom_open(&core,core_dir,cfg->core_name,geteuid(),cfg->core_sha256),core_error=errno;
 if(close(core_dir)&&!core_bad){core_bad=-1;core_error=EIO;}
 if(core_bad){if(core.ready)hc_verified_launch_close(&core);errno=core_error;return -1;}
 int objects=open(cfg->objects_root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(objects<0){int err=errno;hc_verified_launch_close(&core);errno=err;return -1;}
 int profiles=open(cfg->profiles_root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(profiles<0){int err=errno;close(objects);hc_verified_launch_close(&core);errno=err;return -1;}
 int game=openat(profiles,request.game,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);int saved=errno;close(profiles);if(game<0){close(objects);hc_verified_launch_close(&core);errno=saved;return -1;}
 HCFrontendIsolatedSpec spec={.rom_directory=objects,.inherited_rom=cfg->rom_fd,.game_profile=game,.binding_dir=-1,.uid=geteuid(),.rom_name=name,.rom_path=rom,.profile_path=profile,.frontend_sram=sram,.binding_name=binding,.retention=HC_RETENTION_KEEP_PREVIOUS,.startup_fd=cfg->startup_fd,.exit_fd=cfg->exit_fd,.confirm_fd=cfg->confirm_fd,.binding_in_save_dir=1};
 int result=hc_frontend_bootstrap_receive_isolated(boot,&spec,cfg->input_fd,cfg->timeout_ms,&request);saved=errno;int ca=close(game),cb=close(objects);
 if(result||ca||cb||hc_verified_launch_recheck(&core)){
  if(!result)boot->ready=0;hc_verified_launch_close(&core);errno=result?saved:EIO;return -1;
 }
 verified_core=core;memcpy(expected_core_path,core_path,(size_t)e+1);
 if(with_image||with_save){HCManagerCheckpointPaths paths={0};
  if(hc_frontend_entry_observe_manager(boot,cfg,&paths)||paths.have_image!=with_image||(with_image&&strcmp(paths.image,args[6]))||paths.have_save!=with_save||(with_save&&strcmp(paths.save,args[save_index+1]))){
   boot->ready=0;(void)hc_verified_launch_close(&verified_core);expected_core_path[0]=0;errno=EIO;return -1;
  }
  boot->manager_paths=paths;boot->manager_paths_ready=1;
 }
 entry_bootstrap=boot;
 args[3]=args[core_index];args[4]=args[core_index+1];args[5]=args[core_index+2];args[6]=NULL;*count=6;return 0;
}
