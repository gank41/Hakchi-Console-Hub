#define _POSIX_C_SOURCE 200809L
#include "stock-manager-state.h"
#include "recovery-binding.h"
#include "nonce-sequence.h"
#include "owned_directory.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#if defined(HC_STOCK_MANAGER_HOST_ROOT) && defined(__arm__)
#error "Manager path remapping is host-only"
#endif
#if defined(HC_STOCK_MANAGER_STATE_TEST_HOOK) && defined(__arm__)
#error "Manager state interruption injection is host-only"
#endif
#ifdef HC_STOCK_MANAGER_STATE_TEST_HOOK
extern void hc_test_manager_state_hook(int);
#define HC_MANAGER_STATE_HOOK(stage) hc_test_manager_state_hook(stage)
#else
#define HC_MANAGER_STATE_HOOK(stage) ((void)0)
#endif
static int physical_path(const char *logical,char path[1024]){
 if(!logical||logical[0]!='/'){errno=EINVAL;return -1;}
#ifdef HC_STOCK_MANAGER_HOST_ROOT
 static const char prefix[]="/var/cache/clover/volatile/";
 if(strncmp(logical,prefix,sizeof prefix-1)){errno=EINVAL;return -1;}
 int n=snprintf(path,1024,"%s/%s",HC_STOCK_MANAGER_HOST_ROOT,logical+sizeof prefix-1);
#else
 int n=snprintf(path,1024,"%s",logical);
#endif
 if(n<=0||n>=1024){errno=EINVAL;return -1;}return 0;
}
int hc_stock_manager_state_preflight(HCStockManagerState *out,HCStockGameSession *game,HCConsoleRuntime *runtime,HCConsoleGame *menu,int parent){
 struct stat dir,item;char path[1024];
 if(!out||out->attempted||out->published||out->target.ready||!game||!runtime||!runtime->claimed||runtime->workspace<3||!menu||!menu->rom.ready||
    !menu->command.checkpoint.have_save||!(menu->command.manager.present&(1u<<HC_ROLLBACK_OUT))||
    strcmp(menu->command.game,game->game)||strcmp(menu->command.digest,game->rom.sha256)||strcmp(menu->rom.sha256,game->rom.sha256)||
    strcmp(runtime->request.game,game->game)||strcmp(runtime->request.digest,game->rom.sha256)||memcmp(runtime->request.session,game->token,16)||runtime->request.epoch!=game->epoch||
    hc_verified_launch_recheck(&game->rom)||hc_verified_launch_recheck(&menu->rom)||
    hc_console_game_check_manager_record_full(runtime->workspace,&runtime->request,&menu->command.checkpoint,&menu->command.time)||
    physical_path(menu->command.checkpoint.save,path)||parent<3||fcntl(parent,F_GETFD)<0||!(fcntl(parent,F_GETFD)&FD_CLOEXEC)||
    fstat(parent,&dir)||!S_ISDIR(dir.st_mode)||dir.st_uid!=geteuid()||(dir.st_mode&0777)!=0700){errno=EINVAL;return -1;}
 const char *base=strrchr(path,'/');HCSessionExpected region={parent,path,108};
 if(!base||strcmp(base+1,"savestate")||hc_session_validate_regions(&region,1)||
    !fstatat(parent,base+1,&item,AT_SYMLINK_NOFOLLOW)||errno!=ENOENT||
    !fstatat(parent,"state-manager-binding",&item,AT_SYMLINK_NOFOLLOW)||errno!=ENOENT){errno=EINVAL;return -1;}
 return 0;
}
static int package_matches(const HCStateBytes *package,HCStockStateReceipt *state){
 HCStateBytes raw=HC_STATE_BYTES_INITIALIZER;
 if(!package||!package->data||package->length<18||!state||!state->bytes||!state->length||
    package->data[0]!=0x1f||package->data[1]!=0x8b||hc_state_decode(package->data,package->length,&raw)){errno=EINVAL;return -1;}
 int ok=raw.length==state->length&&!memcmp(raw.data,state->bytes,state->length);hc_state_bytes_clear(&raw);
 if(!ok){errno=EINVAL;return -1;}return 0;
}
int hc_stock_manager_state_recheck(HCStockManagerState *out,HCStockGameSession *game,HCConsoleRuntime *runtime,HCConsoleGame *menu,HCStockControlSession *control,HCStockStateReceipt *state,HCStockStateArchive *archive,const HCStateBytes *package,int parent){
 char path[1024];struct stat dir,target,held;HCIV2Entry entries[16];size_t count=0;int fd=-1,ok=0;
 if(!out||!out->attempted||!out->published||!out->target.ready||!out->target.consumed||!game||!runtime||!menu||parent<3||
    !menu->command.checkpoint.have_save||!(menu->command.manager.present&(1u<<HC_ROLLBACK_OUT))||
    !menu->rom.ready||strcmp(menu->command.game,game->game)||strcmp(menu->command.digest,game->rom.sha256)||strcmp(menu->rom.sha256,game->rom.sha256)||hc_verified_launch_recheck(&menu->rom)||
    hc_console_game_check_manager_record_full(runtime->workspace,&runtime->request,&menu->command.checkpoint,&menu->command.time)||
    hc_stock_state_archive_recheck(archive,state,game,runtime,control)||package_matches(package,state)||
    physical_path(menu->command.checkpoint.save,path)||strcmp(path,out->path)||strcmp(path,out->target.identity)||
    fstat(parent,&dir)||fstat(out->target.parent,&held)||!S_ISDIR(dir.st_mode)||dir.st_uid!=geteuid()||(dir.st_mode&0777)!=0700||
    dir.st_dev!=held.st_dev||dir.st_ino!=held.st_ino){errno=EINVAL;return -1;}
 HCSessionExpected region={parent,path,108};
 if(hc_session_validate_regions(&region,1)||hc_binding_inventory(parent,"state-manager-binding",game->game,game->rom.sha256,game->token,game->epoch,&region,1,0,entries,16,&count)||
    count!=1||strcmp(entries[0].workspace,out->target.workspace_name)||strcmp(entries[0].region,"savestate")||entries[0].kind!=HCIV2_FINAL||!entries[0].workspace_present)return -1;
 fd=openat(parent,"savestate",O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return -1;
 if(!fstat(fd,&target)&&!fstatat(parent,"savestate",&held,AT_SYMLINK_NOFOLLOW)&&target.st_dev==held.st_dev&&target.st_ino==held.st_ino&&
    !hc_verify_checkpoint_file(fd,geteuid(),package->data,package->length)&&!fstatat(parent,"savestate",&held,AT_SYMLINK_NOFOLLOW)&&
    target.st_dev==held.st_dev&&target.st_ino==held.st_ino)ok=1;
 int saved=errno;if(close(fd))ok=0;if(!ok){errno=saved?saved:EIO;return -1;}return 0;
}
int hc_stock_manager_state_publish(HCStockManagerState *out,HCStockGameSession *game,HCConsoleRuntime *runtime,HCConsoleGame *menu,HCStockControlSession *control,HCStockStateReceipt *state,HCStockStateArchive *archive,const HCStateBytes *package,int parent){
 HCNonceSequence sequence=HC_NONCE_SEQUENCE_INITIALIZER;uint8_t nonce[16];char session[33],workspace[44];static const char hex[]="0123456789abcdef";
 if(hc_stock_manager_state_preflight(out,game,runtime,menu,parent)||hc_stock_state_archive_recheck(archive,state,game,runtime,control)||package_matches(package,state)||physical_path(menu->command.checkpoint.save,out->path))return -1;
 HCSessionExpected region={parent,out->path,108};
 if(hc_nonce_sequence_init(&sequence))return -1;
 int r=hc_nonce_sequence_next(&sequence,nonce),saved=errno;if(hc_nonce_sequence_destroy(&sequence)&&!r){r=-1;saved=errno;}if(r){errno=saved;return -1;}
 if(!memcmp(nonce,game->token,16)){errno=EINVAL;return -1;}
 memcpy(workspace,"checkpoint-",11);for(size_t i=0;i<16;i++){session[2*i]=hex[game->token[i]>>4];session[2*i+1]=hex[game->token[i]&15];workspace[11+2*i]=hex[nonce[i]>>4];workspace[12+2*i]=hex[nonce[i]&15];}session[32]=0;workspace[43]=0;
 out->attempted=1;
 if(hc_binding_create(parent,"state-manager-binding",game->game,game->rom.sha256,game->token,game->epoch,&region,1))return -2;
 HC_MANAGER_STATE_HOOK(1);
 if(hciv2_create(parent,session,workspace,"savestate",HCIV2_FINAL))return -2;
 HC_MANAGER_STATE_HOOK(2);
 if(hc_autosave_target_prepare(&out->target,parent,geteuid(),nonce,out->path,"savestate")||
    hc_stock_state_archive_recheck(archive,state,game,runtime,control)||package_matches(package,state)||
    hc_autosave_target_write(&out->target,out->path,package->data,package->length))return -2;
 HC_MANAGER_STATE_HOOK(3);
 HCIV2Entry entries[16];size_t count=0;
 if(hc_binding_inventory(parent,"state-manager-binding",game->game,game->rom.sha256,game->token,game->epoch,&region,1,0,entries,16,&count)||
    count!=1||strcmp(entries[0].workspace,workspace)||strcmp(entries[0].region,"savestate")||entries[0].kind!=HCIV2_FINAL||!entries[0].workspace_present||
    hc_stock_state_archive_recheck(archive,state,game,runtime,control)||package_matches(package,state))return -2;
 out->published=1;
 if(hc_stock_manager_state_recheck(out,game,runtime,menu,control,state,archive,package,parent))return -2;
 return 0;
}
int hc_stock_manager_state_close(HCStockManagerState *out){
 if(!out||!out->attempted){errno=EINVAL;return -1;}
 if(out->target.ready&&hc_autosave_target_close(&out->target))return -1;
 out->published=0;return 0;
}
