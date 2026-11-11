#define _POSIX_C_SOURCE 200809L
#include "stock-selected-state.h"
#include "stock-state-seed.h"
#include "stock-gameplay.h"
#include "state_codec.h"
#include "recovery-observer.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#if defined(HC_STOCK_MANAGER_HOST_ROOT) && defined(__arm__)
#error "Manager path remapping is host-only"
#endif
#if defined(HC_STOCK_SELECTED_BIND_TEST_HOOK) && defined(__arm__)
#error "Selected-state bind fault injection is host-only"
#endif
static int path_for(const char *logical,char physical[1024]){
 if(!logical||logical[0]!='/'){errno=EINVAL;return -1;}
#ifdef HC_STOCK_MANAGER_HOST_ROOT
 static const char prefix[]="/var/cache/clover/volatile/";
 if(strncmp(logical,prefix,sizeof prefix-1)){errno=EINVAL;return -1;}
 int n=snprintf(physical,1024,"%s/%s",HC_STOCK_MANAGER_HOST_ROOT,logical+sizeof prefix-1);
#else
 int n=snprintf(physical,1024,"%s",logical);
#endif
 if(n<=0||n>=1024){errno=EINVAL;return -1;}return 0;
}
static int same_file(const struct stat *a,const struct stat *b){
 if(a->st_dev!=b->st_dev||a->st_ino!=b->st_ino||a->st_uid!=b->st_uid||a->st_mode!=b->st_mode||a->st_nlink!=b->st_nlink||a->st_size!=b->st_size)return 0;
#ifdef __APPLE__
 return a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec&&a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec&&a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec&&a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec;
#else
 return a->st_mtim.tv_sec==b->st_mtim.tv_sec&&a->st_mtim.tv_nsec==b->st_mtim.tv_nsec&&a->st_ctim.tv_sec==b->st_ctim.tv_sec&&a->st_ctim.tv_nsec==b->st_ctim.tv_nsec;
#endif
}
static int same_profiles_root(const HCStockSelectedState *s){
 char expected[1024];if(!s||!s->game)return 0;
 int n=snprintf(expected,sizeof expected,"%s/%s/hakchi/%s/%s/battery.srm",s->profiles_root,s->game->game,HC_COMPATIBILITY_ENGINE_ID,s->game->rom.sha256);
 return n>0&&(size_t)n<sizeof expected&&strnlen(s->game->save.identity,sizeof s->game->save.identity)<sizeof s->game->save.identity&&
        !strcmp(expected,s->game->save.identity);
}
/* Resolve only the selected manager path under the caller-pinned volatile
 * root. Every child is opened without following links and held until the
 * complete ancestry is rechecked. This does not authenticate the root. */
int hc_stock_selected_open_parent(const HCConsoleGame *game,int root,uid_t uid){
 static const char prefix[]="/var/cache/clover/volatile/";
 int held[33];char names[32][256];struct stat snapshots[33],current,named;size_t depth=0;int ok=0,result=-1;
 for(size_t i=0;i<33;i++)held[i]=-1;
 if(!game||root<3||uid!=geteuid()||fcntl(root,F_GETFD)<0||!(fcntl(root,F_GETFD)&FD_CLOEXEC)||
    !game->command.checkpoint.have_load||!(game->command.manager.present&(1u<<HC_ROLLBACK_IN))||
    (game->command.manager.present&(1u<<HC_LOAD))||strnlen(game->command.game,sizeof game->command.game)!=11||
    strnlen(game->command.checkpoint.load,1024)>=1024||strnlen(game->command.manager.values[HC_ROLLBACK_IN],1024)>=1024){errno=EINVAL;return -1;}
 const char *path=game->command.checkpoint.load,*rollback=game->command.manager.values[HC_ROLLBACK_IN];
 size_t base_length=strlen(rollback),game_length=strlen(game->command.game);
 if(strncmp(path,prefix,sizeof prefix-1)||!base_length||base_length+10>=1024||strncmp(path,rollback,base_length)||strcmp(path+base_length,"/savestate")){errno=EINVAL;return -1;}
 const char *relative=path+sizeof prefix-1;
 if(strncmp(relative,game->command.game,game_length)||relative[game_length]!='/'){errno=EINVAL;return -1;}
 held[0]=openat(root,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(held[0]<0)goto done;
 if(fstat(root,&current)||fstat(held[0],&snapshots[0])||!S_ISDIR(current.st_mode)||current.st_uid!=uid||(current.st_mode&0022)||
    current.st_dev!=snapshots[0].st_dev||current.st_ino!=snapshots[0].st_ino||current.st_mode!=snapshots[0].st_mode||current.st_uid!=snapshots[0].st_uid)goto done;
 const char *cursor=relative;
 for(;;){
  const char *slash=strchr(cursor,'/');if(!slash||depth>=32){errno=EINVAL;goto done;}
  size_t length=(size_t)(slash-cursor);if(!length||length>=sizeof names[0]||(length==1&&cursor[0]=='.')||(length==2&&cursor[0]=='.'&&cursor[1]=='.')){errno=EINVAL;goto done;}
  for(size_t i=0;i<length;i++){unsigned char c=(unsigned char)cursor[i];if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='-'||c=='_'||c=='.')){errno=EINVAL;goto done;}}
  memcpy(names[depth],cursor,length);names[depth][length]=0;
  if(fstatat(held[depth],names[depth],&named,AT_SYMLINK_NOFOLLOW)||!S_ISDIR(named.st_mode)||named.st_uid!=uid||(named.st_mode&0022))goto done;
  held[depth+1]=openat(held[depth],names[depth],O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(held[depth+1]<0)goto done;
  if(fstat(held[depth+1],&snapshots[depth+1])||snapshots[depth+1].st_dev!=named.st_dev||snapshots[depth+1].st_ino!=named.st_ino||
     snapshots[depth+1].st_mode!=named.st_mode||snapshots[depth+1].st_uid!=named.st_uid)goto done;
  depth++;cursor=slash+1;
  if(!strcmp(cursor,"savestate"))break;
 }
 if(depth<2||(snapshots[depth].st_mode&0777)!=0700)goto done;
 for(size_t i=0;i<depth;i++)if(fstat(held[i+1],&current)||fstatat(held[i],names[i],&named,AT_SYMLINK_NOFOLLOW)||
    !S_ISDIR(named.st_mode)||current.st_dev!=snapshots[i+1].st_dev||current.st_ino!=snapshots[i+1].st_ino||current.st_mode!=snapshots[i+1].st_mode||current.st_uid!=snapshots[i+1].st_uid||
    named.st_dev!=current.st_dev||named.st_ino!=current.st_ino||named.st_mode!=current.st_mode||named.st_uid!=current.st_uid)goto done;
 if(fstat(root,&current)||current.st_dev!=snapshots[0].st_dev||current.st_ino!=snapshots[0].st_ino||current.st_mode!=snapshots[0].st_mode||current.st_uid!=snapshots[0].st_uid)goto done;
 result=held[depth];held[depth]=-1;ok=1;
done: {int saved=errno;for(size_t i=0;i<33;i++)if(held[i]>=0&&close(held[i]))ok=0;
 if(!ok){if(result>=0)close(result);errno=saved?saved:EIO;return -1;}return result;}
}
int hc_stock_selected_open_console_parent(const HCConsoleGame *game,uid_t uid){
#ifdef HC_STOCK_MANAGER_HOST_ROOT
 const char *path=HC_STOCK_MANAGER_HOST_ROOT;
#else
 const char *path="/var/cache/clover/volatile";
#endif
 struct stat before,after;int root=-1,named=-1,parent=-1,ok=0;
 if(uid!=geteuid()){errno=EINVAL;return -1;}
 root=open(path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(root<0)goto done;
 if(fstat(root,&before)||!S_ISDIR(before.st_mode)||before.st_uid!=uid||(before.st_mode&0022))goto done;
 parent=hc_stock_selected_open_parent(game,root,uid);if(parent<0)goto done;
 named=open(path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
 if(named<0||fstat(named,&after)||before.st_dev!=after.st_dev||before.st_ino!=after.st_ino||before.st_uid!=after.st_uid||before.st_mode!=after.st_mode||
    fstat(root,&after)||before.st_dev!=after.st_dev||before.st_ino!=after.st_ino||before.st_uid!=after.st_uid||before.st_mode!=after.st_mode)goto done;
 ok=1;
done: {int saved=errno;if(named>=0&&close(named))ok=0;if(root>=0&&close(root))ok=0;
 if(!ok){if(parent>=0)close(parent);errno=saved?saved:EIO;return -1;}return parent;}
}
static int same_inventory(const HCManagerRecordObservation *a,const HCManagerRecordObservation *b,size_t count){
 for(size_t i=0;i<count;i++){
  if(strcmp(a[i].workspace,b[i].workspace)||a[i].status!=b[i].status)return 0;
  if(a[i].status==HC_MANAGER_RECORD_PRESENT){
   unsigned char x[HC_LAUNCH_REQUEST_SIZE],y[HC_LAUNCH_REQUEST_SIZE];
   if(hc_launch_request_encode(&a[i].request,x)||hc_launch_request_encode(&b[i].request,y)||memcmp(x,y,sizeof x)||
      a[i].paths.have_save!=b[i].paths.have_save||a[i].paths.have_image!=b[i].paths.have_image||a[i].paths.have_load!=b[i].paths.have_load||
      strcmp(a[i].paths.save,b[i].paths.save)||strcmp(a[i].paths.image,b[i].paths.image)||strcmp(a[i].paths.load,b[i].paths.load)||
      a[i].time.have_load!=b[i].time.have_load||a[i].time.have_save!=b[i].time.have_save||
      strcmp(a[i].time.load,b[i].time.load)||strcmp(a[i].time.save,b[i].time.save))return 0;
  }
 }
 return 1;
}
/* Read-only correlation: selected manager state is matched against complete
 * session archives. The caller holds the game lock and authenticates roots;
 * neither a unique match nor the records authenticate the console. */
int hc_stock_selected_state_identify(HCStockGameSession *game,HCConsoleRuntime *runtime,HCConsoleGame *menu,int parent,int profiles,const char *root,HCLaunchRequest *out){
 HCStockSelectedState selected=HC_STOCK_SELECTED_STATE_INITIALIZER;HCStateBytes raw=HC_STATE_BYTES_INITIALIZER;
 HCManagerRecordObservation *before=NULL,*after=NULL;HCRecoveryObservation *observation=NULL;
 unsigned char *compressed=NULL,*archive=NULL;struct stat st,named,dir;size_t count=0,again=0,archive_capacity=0,inventory_capacity=16;int sessions=-1,session=-1,archive_dir=-1,fd=-1,ok=0,matches=0;HCLaunchRequest found={0};
 if(!game||!runtime||!menu||!root||root[0]!='/'||strnlen(root,1024)>=1024||!out||parent<3||profiles<3||
    fcntl(parent,F_GETFD)<0||!(fcntl(parent,F_GETFD)&FD_CLOEXEC)||fcntl(profiles,F_GETFD)<0||!(fcntl(profiles,F_GETFD)&FD_CLOEXEC)||
    game->save.phase!=HC_STOCK_PREPARED||!menu->command.checkpoint.have_load||
    !(menu->command.manager.present&(1u<<HC_ROLLBACK_IN))||(menu->command.manager.present&(1u<<HC_LOAD))||
    strcmp(menu->command.game,game->game)||strcmp(menu->command.digest,game->rom.sha256)||
    strcmp(runtime->request.game,game->game)||strcmp(runtime->request.digest,game->rom.sha256)||
    memcmp(runtime->request.session,game->token,16)||runtime->request.epoch!=game->epoch||
    hc_verified_launch_recheck(&menu->rom)||hc_stock_game_recheck(game)||
    hc_console_game_check_manager_record_full(runtime->workspace,&runtime->request,&menu->command.checkpoint,&menu->command.time)){errno=EINVAL;return -1;}
 size_t load_length=strnlen(menu->command.checkpoint.load,1024),rollback_length=strnlen(menu->command.manager.values[HC_ROLLBACK_IN],1024);
 if(!load_length||load_length>=1024||!rollback_length||rollback_length>=1024||rollback_length+10>=1024||
    strncmp(menu->command.checkpoint.load,menu->command.manager.values[HC_ROLLBACK_IN],rollback_length)||
    strcmp(menu->command.checkpoint.load+rollback_length,"/savestate")){errno=EINVAL;return -1;}
 selected.game=game;selected.runtime=runtime;selected.menu=menu;selected.parent=parent;selected.profiles=profiles;
 memcpy(selected.logical,menu->command.checkpoint.load,load_length+1);strcpy(selected.profiles_root,root);
 if(!same_profiles_root(&selected)||path_for(selected.logical,selected.physical)||fstat(parent,&dir)||!S_ISDIR(dir.st_mode)||dir.st_uid!=geteuid()||(dir.st_mode&0777)!=0700)goto done;
 const char *base=strrchr(selected.physical,'/');HCSessionExpected region={parent,selected.physical,109};
 if(!base||strcmp(base+1,"savestate")||hc_session_validate_regions(&region,1))goto done;
 fd=openat(parent,base+1,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(fd<0||fstat(fd,&st)||fstatat(parent,base+1,&named,AT_SYMLINK_NOFOLLOW)||
    !S_ISREG(st.st_mode)||st.st_uid!=geteuid()||(st.st_mode&0777)!=0600||st.st_nlink!=1||st.st_size<18||st.st_size>(off_t)(HC_STATE_BYTES_MAX+65536u)||!same_file(&st,&named))goto done;
 compressed=malloc((size_t)st.st_size);if(!compressed)goto done;
 for(size_t p=0;p<(size_t)st.st_size;){ssize_t n=pread(fd,compressed+p,(size_t)st.st_size-p,(off_t)p);if(n<0&&errno==EINTR)continue;if(n<=0)goto done;p+=(size_t)n;}
 if(compressed[0]!=0x1f||compressed[1]!=0x8b||hc_state_decode(compressed,(size_t)st.st_size,&raw))goto done;
 sessions=hc_console_game_open_persistent_sessions(profiles,root,geteuid(),game->game,game->rom.sha256);if(sessions<0)goto done;
 observation=calloc(1,sizeof *observation);if(!observation)goto done;
 for(;;){
  before=calloc(inventory_capacity,sizeof *before);if(!before)goto done;
  if(!hc_console_game_inventory_manager_records(sessions,game->game,game->rom.sha256,before,inventory_capacity,&count))break;
  if(errno!=ENOSPC||inventory_capacity==HC_MANAGER_INVENTORY_MAX)goto done;
  free(before);before=NULL;inventory_capacity*=2;
 }
 after=calloc(inventory_capacity,sizeof *after);if(!after)goto done;
 for(size_t i=0;i<count;i++){
  if(before[i].status!=HC_MANAGER_RECORD_PRESENT){errno=EBUSY;goto done;}
  if(!memcmp(before[i].request.session,runtime->request.session,16))continue;
  session=openat(sessions,before[i].workspace,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(session<0)goto done;
  if(fstatat(session,"state-archive",&named,AT_SYMLINK_NOFOLLOW)){
   if(errno!=ENOENT)goto done;int closed=close(session);session=-1;if(closed)goto done;continue;
  }
  if(!S_ISDIR(named.st_mode)||named.st_uid!=geteuid()||(named.st_mode&0777)!=0700){errno=EINVAL;goto done;}
  archive_dir=openat(session,"state-archive",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(archive_dir<0||fstatat(archive_dir,"state-captured",&named,AT_SYMLINK_NOFOLLOW)||
     !S_ISREG(named.st_mode)||named.st_uid!=geteuid()||(named.st_mode&0777)!=0600||named.st_nlink!=1||named.st_size<=0||named.st_size>(off_t)HC_STATE_BYTES_MAX)goto done;
  if((size_t)named.st_size>archive_capacity){unsigned char *larger=realloc(archive,(size_t)named.st_size);if(!larger)goto done;archive=larger;archive_capacity=(size_t)named.st_size;}
  int closed=close(archive_dir);archive_dir=-1;if(closed)goto done;
  closed=close(session);session=-1;if(closed)goto done;size_t length=0;
  if(hc_recovery_collect_game_state_archive(profiles,root,geteuid(),&before[i].request,observation,archive,archive_capacity,&length))goto done;
  if(length==raw.length&&!memcmp(archive,raw.data,raw.length)){found=before[i].request;if(++matches>1){errno=EEXIST;goto done;}}
 }
 if(matches!=1){errno=ENOENT;goto done;}
 if(hc_console_game_inventory_manager_records(sessions,game->game,game->rom.sha256,after,inventory_capacity,&again)||again!=count||!same_inventory(before,after,count)||
    fstat(fd,&named)||!same_file(&st,&named)||fstatat(parent,base+1,&named,AT_SYMLINK_NOFOLLOW)||!same_file(&st,&named)||
    hc_console_game_check_manager_record_full(runtime->workspace,&runtime->request,&menu->command.checkpoint,&menu->command.time)||hc_stock_game_recheck(game))goto done;
 ok=1;
done: {int saved=errno;if(archive_dir>=0&&close(archive_dir))ok=0;if(session>=0&&close(session))ok=0;if(sessions>=0&&close(sessions))ok=0;if(fd>=0&&close(fd))ok=0;
 free(before);free(after);free(observation);free(compressed);free(archive);hc_state_bytes_clear(&raw);
 if(!ok){errno=saved?saved:EIO;return -1;}*out=found;return 0;}
}
/* Returns verified compressed bytes to the caller, without mutating the game. */
static int checked(HCStockSelectedState *s,HCStateBytes *encoded,int staged){
 struct stat held,named,dir;char physical[1024];unsigned char *bytes=NULL,*archive=NULL;HCStateBytes raw=HC_STATE_BYTES_INITIALIZER;HCRecoveryObservation observation;size_t archived=0;int ok=0;
 if(!s||!s->ready||s->fd<3||s->parent<3||s->profiles<3||!s->game||!s->runtime||!s->menu||!encoded||encoded->data||encoded->length||
    !s->menu->command.checkpoint.have_load||!(s->menu->command.manager.present&(1u<<HC_ROLLBACK_IN))||
    strcmp(s->logical,s->menu->command.checkpoint.load)||path_for(s->logical,physical)||strcmp(physical,s->physical)||
    strcmp(s->prior.game,s->game->game)||strcmp(s->prior.digest,s->game->rom.sha256)||!same_profiles_root(s)||
    strcmp(s->runtime->request.game,s->game->game)||strcmp(s->runtime->request.digest,s->game->rom.sha256)||
    !memcmp(s->runtime->request.session,s->prior.session,16)||memcmp(s->runtime->request.session,s->game->token,16)||s->runtime->request.epoch!=s->game->epoch||
    strcmp(s->menu->command.game,s->game->game)||strcmp(s->menu->command.digest,s->game->rom.sha256)||
    hc_verified_launch_recheck(&s->menu->rom)||hc_stock_game_recheck(s->game)||
    hc_console_game_check_manager_record_full(s->runtime->workspace,&s->runtime->request,&s->menu->command.checkpoint,&s->menu->command.time)||
    fstat(s->parent,&dir)||!S_ISDIR(dir.st_mode)||dir.st_uid!=geteuid()||(dir.st_mode&0777)!=0700){errno=EINVAL;return -1;}
 const char *base=strrchr(s->physical,'/');HCSessionExpected region={s->parent,s->physical,109};
 if(!base||strcmp(base+1,"savestate")||hc_session_validate_regions(&region,1)||fstat(s->fd,&held)||fstatat(s->parent,base+1,&named,AT_SYMLINK_NOFOLLOW)||
    !S_ISREG(held.st_mode)||held.st_uid!=geteuid()||(held.st_mode&0777)!=0600||held.st_nlink!=1||held.st_size<18||held.st_size>(off_t)(HC_STATE_BYTES_MAX+65536u)||
    !same_file(&s->snapshot,&held)||!same_file(&held,&named)){errno=EINVAL;return -1;}
 size_t size=(size_t)held.st_size;bytes=malloc(size);if(!bytes)return -1;
 for(size_t p=0;p<size;){ssize_t n=pread(s->fd,bytes+p,size-p,(off_t)p);if(n<0&&errno==EINTR)continue;if(n<=0)goto done;p+=(size_t)n;}
 if(bytes[0]!=0x1f||bytes[1]!=0x8b||hc_state_decode(bytes,size,&raw))goto done;
 archive=malloc(raw.length);if(!archive)goto done;
 if(hc_recovery_collect_game_state_archive(s->profiles,s->profiles_root,geteuid(),&s->prior,&observation,archive,raw.length,&archived)||
    archived!=raw.length||memcmp(archive,raw.data,raw.length)||
    (staged&&(!s->game->autoload_bytes||s->game->autoload_length!=raw.length||memcmp(s->game->autoload_bytes,raw.data,raw.length)))||
    fstat(s->fd,&held)||fstatat(s->parent,base+1,&named,AT_SYMLINK_NOFOLLOW)||!same_file(&s->snapshot,&held)||!same_file(&held,&named)||
    hc_console_game_check_manager_record_full(s->runtime->workspace,&s->runtime->request,&s->menu->command.checkpoint,&s->menu->command.time)||hc_stock_game_recheck(s->game))goto done;
 encoded->data=bytes;encoded->length=size;bytes=NULL;ok=1;
done: {int saved=errno;free(bytes);free(archive);hc_state_bytes_clear(&raw);if(!ok){errno=saved?saved:EIO;return -1;}return 0;}
}
int hc_stock_selected_state_prepare(HCStockSelectedState *out,HCStockGameSession *game,HCConsoleRuntime *runtime,HCConsoleGame *menu,int parent,int profiles,const char *root,const HCLaunchRequest *prior){
 HCStockSelectedState next=HC_STOCK_SELECTED_STATE_INITIALIZER;HCStateBytes encoded=HC_STATE_BYTES_INITIALIZER;struct stat dir;unsigned char frame[HC_LAUNCH_REQUEST_SIZE];
 if(!out||out->ready||out->fd!=-1||!game||!runtime||!menu||parent<3||profiles<3||!root||root[0]!='/'||strnlen(root,1024)>=1024||!prior||
    hc_launch_request_encode(prior,frame)||game->save.phase!=HC_STOCK_PREPARED||!menu->command.checkpoint.have_load||
    !(menu->command.manager.present&(1u<<HC_ROLLBACK_IN))||(menu->command.manager.present&(1u<<HC_LOAD))||
    fcntl(parent,F_GETFD)<0||!(fcntl(parent,F_GETFD)&FD_CLOEXEC)||fcntl(profiles,F_GETFD)<0||!(fcntl(profiles,F_GETFD)&FD_CLOEXEC)||
    fstat(parent,&dir)||!S_ISDIR(dir.st_mode)||dir.st_uid!=geteuid()||(dir.st_mode&0777)!=0700){errno=EINVAL;return -1;}
 size_t load_length=strnlen(menu->command.checkpoint.load,1024),rollback_length=strnlen(menu->command.manager.values[HC_ROLLBACK_IN],1024);
 if(!load_length||load_length>=1024||!rollback_length||rollback_length>=1024||rollback_length+10>=1024||
    strncmp(menu->command.checkpoint.load,menu->command.manager.values[HC_ROLLBACK_IN],rollback_length)||
    strcmp(menu->command.checkpoint.load+rollback_length,"/savestate")){errno=EINVAL;return -1;}
 next.game=game;next.runtime=runtime;next.menu=menu;next.parent=parent;next.profiles=profiles;next.prior=*prior;
 memcpy(next.logical,menu->command.checkpoint.load,strlen(menu->command.checkpoint.load)+1);strcpy(next.profiles_root,root);
 if(path_for(next.logical,next.physical))return -1;
 const char *base=strrchr(next.physical,'/');if(!base||strcmp(base+1,"savestate")){errno=EINVAL;return -1;}
 next.fd=openat(parent,base+1,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(next.fd<0)return -1;
 if(fstat(next.fd,&next.snapshot)){int saved=errno;close(next.fd);errno=saved;return -1;}next.ready=1;
 if(checked(&next,&encoded,0)){int saved=errno;close(next.fd);errno=saved;return -1;}
 int result=hc_stock_state_seed(game,game->game,game->rom.sha256,encoded.data,encoded.length);hc_state_bytes_clear(&encoded);
 if(result){int saved=errno;close(next.fd);errno=saved;return result;}
 if(checked(&next,&encoded,1)||hc_stock_game_autoload_ready(game,1)){
  int saved=errno;hc_state_bytes_clear(&encoded);close(next.fd);game->fault=1;game->save.phase=HC_STOCK_FAILED;errno=saved?saved:EIO;return -2;
 }
 hc_state_bytes_clear(&encoded);*out=next;return 0;
}
int hc_stock_selected_state_prepare_discovered(HCStockSelectedState *out,HCStockGameSession *game,HCConsoleRuntime *runtime,HCConsoleGame *menu,int parent,int profiles,const char *root,HCLaunchRequest *prior_out){
 HCLaunchRequest prior={0};
 if(!out||out->ready||out->fd!=-1||!prior_out){errno=EINVAL;return -1;}
 if(hc_stock_selected_state_identify(game,runtime,menu,parent,profiles,root,&prior))return -1;
 int result=hc_stock_selected_state_prepare(out,game,runtime,menu,parent,profiles,root,&prior);
 if(result)return result;
 *prior_out=prior;return 0;
}
int hc_stock_gameplay_discover_selected_state(HCStockGameplay *g,HCStockSelectedState *selected,int parent,int profiles,const char *root,HCLaunchRequest *prior_out){
 HCLaunchRequest prior={0};
 if(!g||g->phase!=HC_GAMEPLAY_PREPARED||!g->manager_outputs||!g->entry||!g->session||g->selected_state||
    !g->entry->runtime||!g->entry->game||!selected||selected->ready||selected->fd!=-1||!prior_out){errno=EINVAL;return -1;}
 int result=hc_stock_selected_state_prepare_discovered(selected,g->session,g->entry->runtime,g->entry->game,parent,profiles,root,&prior);
 if(result){if(result==-2)g->phase=HC_GAMEPLAY_RECOVERY;return result;}
#ifdef HC_STOCK_SELECTED_BIND_TEST_HOOK
 extern void hc_test_selected_bind_hook(HCStockSelectedState *);
 hc_test_selected_bind_hook(selected);
#endif
 if(hc_stock_gameplay_bind_selected_state(g,selected)){g->phase=HC_GAMEPLAY_RECOVERY;return -2;}
 *prior_out=prior;return 0;
}
int hc_stock_selected_state_recheck(HCStockSelectedState *s){
 HCStateBytes encoded=HC_STATE_BYTES_INITIALIZER;
 if(checked(s,&encoded,1)||hc_stock_game_autoload_ready(s->game,1)){int saved=errno;hc_state_bytes_clear(&encoded);errno=saved?saved:EIO;return -1;}
 hc_state_bytes_clear(&encoded);return 0;
}
int hc_stock_selected_state_close(HCStockSelectedState *s){
 if(!s||!s->ready||s->fd<3){errno=EINVAL;return -1;}
 int fd=s->fd;s->fd=-1;if(close(fd)){int saved=errno;errno=0;if(fcntl(fd,F_GETFD)!=-1||errno!=EBADF)s->fd=fd;else *s=(HCStockSelectedState)HC_STOCK_SELECTED_STATE_INITIALIZER;errno=saved;return -1;}
 *s=(HCStockSelectedState)HC_STOCK_SELECTED_STATE_INITIALIZER;return 0;
}
