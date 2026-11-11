#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#include "stock-save-session.h"
#include "recovery-binding.h"
#include "periodic-owner.h"
#include "stock-config.h"
#include "control_pipe.h"
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <stdio.h>
#include <sys/stat.h>
#include <signal.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#if defined(HC_STOCK_PREPARE_TEST_HOOK) && defined(__arm__)
#error "Save preparation fault injection is host-only"
#endif
/* The caller excludes concurrent descriptor allocation through close/probe. */
static int close_owned(int *slot){int fd=*slot;*slot=-1;if(!close(fd))return 0;int e=errno;errno=0;if(fcntl(fd,F_GETFD)!=-1||errno!=EBADF)*slot=fd;errno=e?e:EIO;return -1;}
static int save_prepare(HCStockSaveSession *s,int parent,const char *binding,const char *game,const char *rom,const uint8_t token[16],uint64_t epoch,const uint8_t nonce[16],const char *identity,const char *clock){
 size_t retained=0;unsigned any=0;char session[33],workspace[44];static const char hex[]="0123456789abcdef";
 if(!s||s->phase!=HC_STOCK_EMPTY||!token||!nonce||!identity||strnlen(identity,sizeof s->identity)>=sizeof s->identity){errno=EINVAL;return -1;}
 const char *base=strrchr(identity,'/');if(!base||!base[1]){errno=EINVAL;return -1;}
 for(size_t i=0;i<16;i++){any|=nonce[i];session[2*i]=hex[token[i]>>4];session[2*i+1]=hex[token[i]&15];workspace[11+2*i]=hex[nonce[i]>>4];workspace[12+2*i]=hex[nonce[i]&15];}
 if(!any){errno=EINVAL;return -1;}session[32]=0;memcpy(workspace,"checkpoint-",11);workspace[43]=0;
 HCSessionExpected regions[]={{parent,identity,0},{parent,clock,1}};size_t region_count=clock?2:1;
 if(hc_periodic_recovery_status(parent,geteuid(),&retained)||retained){errno=EBUSY;return -1;}
 s->phase=HC_STOCK_FAILED;
 if(hc_binding_create(parent,binding,game,rom,token,epoch,regions,region_count))return -1;
#ifdef HC_STOCK_PREPARE_TEST_HOOK
 {extern void hc_test_save_prepare_after_binding(void);hc_test_save_prepare_after_binding();}
#endif
 if(hciv2_create(parent,session,workspace,base+1,HCIV2_FINAL)||hc_autosave_target_prepare(&s->target,parent,geteuid(),nonce,identity,base+1))return -1;
 memcpy(s->identity,identity,strlen(identity)+1);s->phase=HC_STOCK_PREPARED;return 0;
}
int hc_stock_save_prepare(HCStockSaveSession *s,int parent,const char *binding,const char *game,const char *rom,const uint8_t token[16],uint64_t epoch,const uint8_t nonce[16],const char *identity){
 return save_prepare(s,parent,binding,game,rom,token,epoch,nonce,identity,NULL);
}
int hc_stock_save_prepare_pair(HCStockSaveSession *s,int parent,const char *binding,const char *game,const char *rom,const uint8_t token[16],uint64_t epoch,const uint8_t nonce[16],const char *identity,const char *clock){
 if(!clock){errno=EINVAL;return -1;}
 return save_prepare(s,parent,binding,game,rom,token,epoch,nonce,identity,clock);
}
static int stage_name_ok(const char *s){
 if(!s||!s[0]||!strcmp(s,".")||!strcmp(s,".."))return 0;size_t i=0;
 for(;s[i]&&i<128;i++){unsigned char c=(unsigned char)s[i];if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='-'||c=='_'||c=='.'))return 0;}
 return i>0&&i<128;
}
static int stage_private(int fd,struct stat *st){return !fstat(fd,st)&&S_ISDIR(st->st_mode)&&st->st_uid==geteuid()&&(st->st_mode&0777)==0700;}
int hc_stock_save_validate_stage(int fd,int parent_fd,const char *name,size_t size){
 struct stat stage,parent,file;
 if(!stage_name_ok(name)||!size||size>16u*1024u*1024u||!stage_private(fd,&stage)||
    fstat(parent_fd,&parent)||!S_ISDIR(parent.st_mode)||
    (stage.st_dev==parent.st_dev&&stage.st_ino==parent.st_ino)){errno=EINVAL;return -1;}
 if(!fstatat(fd,name,&file,AT_SYMLINK_NOFOLLOW)){
  if(!S_ISREG(file.st_mode)||file.st_uid!=geteuid()||file.st_nlink!=1||(file.st_mode&0022)||file.st_size!=(off_t)size){errno=EINVAL;return -1;}
 }else if(errno!=ENOENT)return -1;
 return 0;
}
int hc_stock_save_bind_stage(HCStockSaveSession *s,int fd,const char *name,size_t size){
 struct stat stage,workspace;
 if(!s||s->phase!=HC_STOCK_PREPARED||s->stage_dir!=-1||
    hc_stock_save_validate_stage(fd,s->target.parent,name,size)||fstat(fd,&stage)||fstat(s->target.workspace,&workspace)||
    (stage.st_dev==workspace.st_dev&&stage.st_ino==workspace.st_ino)){errno=EINVAL;return -1;}
 int held=fcntl(fd,F_DUPFD_CLOEXEC,3);if(held<0)return -1;
 s->stage_dir=held;s->stage_size=size;memcpy(s->stage_name,name,strlen(name)+1);return 0;
}
static int same_file(const struct stat *a,const struct stat *b){
 if(a->st_dev!=b->st_dev||a->st_ino!=b->st_ino||a->st_size!=b->st_size||a->st_uid!=b->st_uid||a->st_nlink!=b->st_nlink||a->st_mode!=b->st_mode)return 0;
#ifdef __APPLE__
 return a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec&&a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec&&a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec&&a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec;
#else
 return a->st_mtim.tv_sec==b->st_mtim.tv_sec&&a->st_mtim.tv_nsec==b->st_mtim.tv_nsec&&a->st_ctim.tv_sec==b->st_ctim.tv_sec&&a->st_ctim.tv_nsec==b->st_ctim.tv_nsec;
#endif
}
int hc_stock_save_seed_stage(HCStockSaveSession *s){
 struct stat dir,before,held,after,named,created;int source=-1,dest=-1,result=-1,saved=EIO;unsigned char *bytes=NULL,*verify=NULL;
 if(!s||s->phase!=HC_STOCK_PREPARED||s->stage_dir<0||!s->target.ready||!s->stage_size||s->stage_size>16u*1024u*1024u||s->initial_valid){errno=EINVAL;return -1;}
 if(!stage_private(s->stage_dir,&dir)||!stage_private(s->target.parent,&dir)){errno=EINVAL;return -1;}
 if(!fstatat(s->stage_dir,s->stage_name,&named,AT_SYMLINK_NOFOLLOW)){errno=EEXIST;return -1;}if(errno!=ENOENT)return -1;
 if(fstatat(s->target.parent,s->target.destination,&before,AT_SYMLINK_NOFOLLOW)){if(errno==ENOENT){s->initial_valid=1;s->initial_present=0;return 1;}return -1;}
 if(!S_ISREG(before.st_mode)||before.st_uid!=geteuid()||before.st_nlink!=1||(before.st_mode&0022)||before.st_size!=(off_t)s->stage_size){errno=EINVAL;return -1;}
 source=openat(s->target.parent,s->target.destination,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(source<0)return -1;
 if(fstat(source,&held)||!same_file(&before,&held))goto done;
 bytes=malloc(s->stage_size);verify=malloc(s->stage_size);if(!bytes||!verify)goto done;
 for(size_t pos=0;pos<s->stage_size;){ssize_t n=pread(source,bytes+pos,s->stage_size-pos,(off_t)pos);if(n<0&&errno==EINTR)continue;if(n<=0)goto done;pos+=(size_t)n;}
 if(fstat(source,&after)||!same_file(&held,&after)||fstatat(s->target.parent,s->target.destination,&named,AT_SYMLINK_NOFOLLOW)||!same_file(&held,&named))goto done;
 dest=openat(s->stage_dir,s->stage_name,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(dest<0)goto done;
 for(size_t pos=0;pos<s->stage_size;){ssize_t n=write(dest,bytes+pos,s->stage_size-pos);if(n<0&&errno==EINTR)continue;if(n<=0)goto done;pos+=(size_t)n;}
 if(fsync(dest)||fstat(dest,&created)||!S_ISREG(created.st_mode)||created.st_uid!=geteuid()||created.st_nlink!=1||(created.st_mode&0777)!=0600||created.st_size!=(off_t)s->stage_size)goto done;
 for(size_t pos=0;pos<s->stage_size;){ssize_t n=pread(dest,verify+pos,s->stage_size-pos,(off_t)pos);if(n<0&&errno==EINTR)continue;if(n<=0)goto done;pos+=(size_t)n;}
 if(memcmp(bytes,verify,s->stage_size)||fstat(dest,&after)||!same_file(&created,&after)||fstatat(s->stage_dir,s->stage_name,&named,AT_SYMLINK_NOFOLLOW)||!same_file(&created,&named)||!stage_private(s->stage_dir,&dir)||fsync(s->stage_dir)||fstat(source,&after)||!same_file(&held,&after)||fstatat(s->target.parent,s->target.destination,&named,AT_SYMLINK_NOFOLLOW)||!same_file(&held,&named))goto done;
 result=0;
done:
 if(dest>=0&&close(dest))result=-1;if(close(source))result=-1;
 if(!result){s->initial_bytes=bytes;s->initial_length=s->stage_size;s->initial_valid=1;s->initial_present=1;bytes=NULL;}
 free(bytes);free(verify);
 if(result){if(dest>=0)s->phase=HC_STOCK_FAILED;errno=saved;}return result;
}
/* chmod/chown change ctime and mode without writing save contents. Only a
 * replacement or content modification timestamp is relevant here. Even that
 * is not proof that a complete, correct save was written. */
static int same_stage_version(const struct stat *a,const struct stat *b){
 if(a->st_dev!=b->st_dev||a->st_ino!=b->st_ino||a->st_size!=b->st_size)return 0;
#ifdef __APPLE__
 return a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec&&a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec;
#else
 return a->st_mtim.tv_sec==b->st_mtim.tv_sec&&a->st_mtim.tv_nsec==b->st_mtim.tv_nsec;
#endif
}
/* This is a conservative stale-file check, not an acknowledgement that the
 * frontend completed a valid save. The caller must still verify completion. */
static int snapshot_stage(HCStockSaveSession *s){
 struct stat dir,file;
 if(!stage_private(s->stage_dir,&dir))return -1;
 if(fstatat(s->stage_dir,s->stage_name,&file,AT_SYMLINK_NOFOLLOW)){
  if(errno!=ENOENT)return -1;s->stage_was_present=0;
 }else{
  if(!S_ISREG(file.st_mode)||file.st_uid!=geteuid()||file.st_nlink!=1||(file.st_mode&0022)||file.st_size!=(off_t)s->stage_size){errno=EINVAL;return -1;}
  s->stage_before=file;s->stage_was_present=1;
 }
 s->stage_snapshot_taken=1;return 0;
}
int hc_stock_save_start(HCStockSaveSession *s,const char *program,char *const argv[],char *const envp[]){
 if(!s||s->phase!=HC_STOCK_PREPARED||s->stage_dir<0||s->screenshot_write>=0){errno=EINVAL;return -1;}
 if(snapshot_stage(s))return -1;
 if(hc_child_start(&s->child,program,argv,envp)){s->phase=HC_STOCK_FAILED;return -1;}s->phase=HC_STOCK_RUNNING;return 0;
}
static int screenshot_writer_valid(HCStockSaveSession *s,int target,int rom_fd){
 if(!s||s->screenshot_write<3||s->screenshot_write==213||s->screenshot_write==target||s->screenshot_write==rom_fd||
    s->screenshot_write==s->cooperative_lock||target==213||s->cooperative_lock<3){errno=EINVAL;return -1;}
 struct stat now,other;int flags=fcntl(s->screenshot_write,F_GETFL),fdflags=fcntl(s->screenshot_write,F_GETFD);
 if(flags<0||fdflags<0||(flags&O_ACCMODE)!=O_WRONLY||!(flags&O_NONBLOCK)||!(fdflags&FD_CLOEXEC)||
    fstat(s->screenshot_write,&now)||!S_ISFIFO(now.st_mode)||now.st_dev!=s->screenshot_snapshot.st_dev||now.st_ino!=s->screenshot_snapshot.st_ino){errno=EINVAL;return -1;}
 int report[2]={s->report_read,s->report_write};
 for(unsigned i=0;i<2;i++)if(report[i]>=0&&(report[i]==s->screenshot_write||fstat(report[i],&other)||(S_ISFIFO(other.st_mode)&&other.st_dev==now.st_dev&&other.st_ino==now.st_ino))){errno=EINVAL;return -1;}
 errno=0;if(fcntl(213,F_GETFD)!=-1||errno!=EBADF){errno=EBUSY;return -1;}return 0;
}
int hc_stock_save_take_screenshot_receipt(HCStockSaveSession *s,int fd){
 struct stat st,other;int flags=fcntl(fd,F_GETFL),fdflags=fcntl(fd,F_GETFD);
 if(!s||s->phase!=HC_STOCK_PREPARED||s->screenshot_write!=-1||fd<3||fd==213||flags<0||fdflags<0||
    (flags&O_ACCMODE)!=O_WRONLY||!(flags&O_NONBLOCK)||!(fdflags&FD_CLOEXEC)||fstat(fd,&st)||!S_ISFIFO(st.st_mode)){errno=EINVAL;return -1;}
 int report[2]={s->report_read,s->report_write};
 for(unsigned i=0;i<2;i++)if(report[i]>=0&&(report[i]==fd||fstat(report[i],&other)||(S_ISFIFO(other.st_mode)&&other.st_dev==st.st_dev&&other.st_ino==st.st_ino))){errno=EINVAL;return -1;}
 s->screenshot_write=fd;s->screenshot_enabled=1;s->screenshot_snapshot=st;return 0;
}
int hc_stock_save_start_rom(HCStockSaveSession *s,HCVerifiedLaunch *rom,int target,const char *program,char *const argv[],char *const envp[]){
 char path[64],name[32];
 if(!s||s->phase!=HC_STOCK_PREPARED||s->stage_dir<0||!rom||!rom->ready||!program||!argv||!argv[0]||strcmp(argv[0],program)||target<3||target>255){errno=EINVAL;return -1;}
#ifdef __APPLE__
 int p=snprintf(path,sizeof path,"/dev/fd/%d",target);
#else
 int p=snprintf(path,sizeof path,"/proc/self/fd/%d",target);
#endif
 int n=snprintf(name,sizeof name,"%d.srm",target);size_t count=0;
 while(count<64&&argv[count])count++;
 if(p<=0||(size_t)p>=sizeof path||n<=0||(size_t)n>=sizeof name||strcmp(name,s->stage_name)||count<2||count==64||strcmp(argv[count-1],path)||hc_verified_launch_recheck(rom)){errno=EINVAL;return -1;}
 if(s->screenshot_enabled!=(s->screenshot_write>=0)){errno=EINVAL;return -1;}
 if(s->screenshot_write>=0&&(!s->report_required||screenshot_writer_valid(s,target,rom->rom_fd)))return -1;
 if(snapshot_stage(s))return -1;
 int started;
 if(s->cooperative_lock>=0){
  started=s->screenshot_write>=0?hc_child_start_rom_reporting_lock_receipt(&s->child,program,argv,envp,rom->rom_fd,target,s->report_write,211,s->cooperative_lock,212,s->screenshot_write,213):s->report_required?hc_child_start_rom_reporting_lock(&s->child,program,argv,envp,rom->rom_fd,target,s->report_write,211,s->cooperative_lock,212):hc_child_start_rom_lock(&s->child,program,argv,envp,rom->rom_fd,target,s->cooperative_lock,212);
 }else started=s->report_required?hc_child_start_rom_reporting(&s->child,program,argv,envp,rom->rom_fd,target,s->report_write,211):hc_child_start_rom(&s->child,program,argv,envp,rom->rom_fd,target);
 int close_failed=0;
 if(s->report_write>=0&&close_owned(&s->report_write))close_failed=1;
 if(s->screenshot_write>=0&&close_owned(&s->screenshot_write))close_failed=1;
 if(started){s->phase=HC_STOCK_FAILED;return -1;}
 s->rom=rom;s->phase=HC_STOCK_RUNNING;
 if(close_failed){s->rom_fault=1;errno=EIO;return -1;}
 /* Child is now owned even if the named ROM changed during spawn. */
 if(hc_verified_launch_recheck(rom)){s->rom_fault=1;errno=EIO;return -1;}return 0;
}
/* Pathname is still used for exec and dlopen; caller must exclude concurrent
 * replacement. The held descriptor and independently supplied digest are not
 * by themselves filesystem locks or proof of trusted content. */
static int checked_path(HCVerifiedLaunch *file,const char *path,int executable){
 struct stat a,b;int fd;
 if(!file||!file->ready||!path||path[0]!='/'||strnlen(path,1024)>=1024||hc_verified_launch_recheck(file)||(executable&&!(file->snapshot.st_mode&S_IXUSR)))return 0;
 fd=open(path,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return 0;
 int ok=!fstat(fd,&a)&&!fstat(file->rom_fd,&b)&&S_ISREG(a.st_mode)&&a.st_dev==b.st_dev&&a.st_ino==b.st_ino;
 if(close(fd))return 0;return ok;
}
static int reviewed_files_ok(HCStockSaveSession *s){
 return s&&s->program&&s->core&&s->config&&checked_path(s->program,s->program_path,1)&&checked_path(s->core,s->core_path,0)&&checked_path(s->config,s->config_path,0)&&!(s->screenshot_enabled?hc_stock_config_validate_screenshot(s->config,s->stage_dir,s->config_dir,s->config_autoload):hc_stock_config_validate(s->config,s->stage_dir,s->config_dir,s->config_autoload));
}
/* Caller authenticates the complete environment. Refuse ambiguous or absent
 * report configuration before spawning, so save confirmation cannot silently
 * be disabled in a reviewed session. */
static int report_environment_ok(char *const envp[]){
 unsigned found=0;size_t i;
 if(!envp)return 0;
 for(i=0;i<4096&&envp[i];i++){
  if(!strncmp(envp[i],"HC_STOCK_SAVE_REPORT=",21)){
   if(strcmp(envp[i],"HC_STOCK_SAVE_REPORT=1"))return 0;
   found++;
  }
 }
 return i<4096&&found==1;
}
int hc_stock_save_preflight_reviewed(HCStockSaveSession *s,HCVerifiedLaunch *rom,int target,HCVerifiedLaunch *program,const char *program_path,HCVerifiedLaunch *core,const char *core_path,HCVerifiedLaunch *config,const char *config_path,int autoload,char *const envp[]){
 struct stat stage,config_parent;char config_dir[1024];
 if(!s||s->phase!=HC_STOCK_PREPARED||s->stage_dir<0||target<3||target>255||target==211||!rom||!rom->ready||hc_verified_launch_recheck(rom)||!report_environment_ok(envp)||!checked_path(program,program_path,1)||!checked_path(core,core_path,0)||!checked_path(config,config_path,0)||
    !stage_private(s->stage_dir,&stage)||fstat(config->parent,&config_parent)||stage.st_dev!=config_parent.st_dev||stage.st_ino!=config_parent.st_ino){errno=EINVAL;return -1;}
 if(s->screenshot_enabled!=(s->screenshot_write>=0)){errno=EINVAL;return -1;}
 if(s->screenshot_write>=0&&screenshot_writer_valid(s,target,rom->rom_fd))return -1;
 struct sigaction child_action;
 if(sigaction(SIGCHLD,NULL,&child_action)||child_action.sa_handler==SIG_IGN||(child_action.sa_flags&SA_NOCLDWAIT)){errno=EINVAL;return -1;}
 errno=0;if(fcntl(target,F_GETFD)!=-1||errno!=EBADF){errno=EBUSY;return -1;}
 errno=0;if(fcntl(211,F_GETFD)!=-1||errno!=EBADF){errno=EBUSY;return -1;}
 if(s->cooperative_lock>=0){if(target==212||s->cooperative_lock==212){errno=EBUSY;return -1;}errno=0;if(fcntl(212,F_GETFD)!=-1||errno!=EBADF){errno=EBUSY;return -1;}}
 const char *last=strrchr(config_path,'/');size_t directory_len=last?(size_t)(last-config_path):0;
 if(!directory_len||directory_len>=sizeof config_dir){errno=EINVAL;return -1;}
 memcpy(config_dir,config_path,directory_len);config_dir[directory_len]=0;
 if(s->screenshot_enabled?hc_stock_config_validate_screenshot(config,s->stage_dir,config_dir,autoload):hc_stock_config_validate(config,s->stage_dir,config_dir,autoload)){errno=EINVAL;return -1;}
 if((program->snapshot.st_dev==core->snapshot.st_dev&&program->snapshot.st_ino==core->snapshot.st_ino)||
    (program->snapshot.st_dev==config->snapshot.st_dev&&program->snapshot.st_ino==config->snapshot.st_ino)||
    (core->snapshot.st_dev==config->snapshot.st_dev&&core->snapshot.st_ino==config->snapshot.st_ino)||
    (rom->snapshot.st_dev==core->snapshot.st_dev&&rom->snapshot.st_ino==core->snapshot.st_ino)){errno=EINVAL;return -1;}
 return 0;
}
int hc_stock_save_start_reviewed(HCStockSaveSession *s,HCVerifiedLaunch *rom,int target,HCVerifiedLaunch *program,const char *program_path,HCVerifiedLaunch *core,const char *core_path,HCVerifiedLaunch *config,const char *config_path,int autoload,char *const envp[]){
 char rom_path[64],config_dir[1024];
 if(hc_stock_save_preflight_reviewed(s,rom,target,program,program_path,core,core_path,config,config_path,autoload,envp))return -1;
 const char *last=strrchr(config_path,'/');size_t directory_len=(size_t)(last-config_path);
 memcpy(config_dir,config_path,directory_len);config_dir[directory_len]=0;
#ifdef __APPLE__
 int n=snprintf(rom_path,sizeof rom_path,"/dev/fd/%d",target);
#else
 int n=snprintf(rom_path,sizeof rom_path,"/proc/self/fd/%d",target);
#endif
 if(n<=0||(size_t)n>=sizeof rom_path){errno=EINVAL;return -1;}
 char *args[]={(char *)program_path,"-v","-c",(char *)config_path,"-L",(char *)core_path,rom_path,NULL};
 int report[2];if(hc_control_pipe(report))return -1;
 s->report_read=report[0];s->report_write=report[1];s->report_required=1;
 s->program=program;s->core=core;s->config=config;
 memcpy(s->program_path,program_path,strlen(program_path)+1);memcpy(s->core_path,core_path,strlen(core_path)+1);memcpy(s->config_path,config_path,strlen(config_path)+1);memcpy(s->config_dir,config_dir,directory_len+1);s->config_autoload=autoload;
 int result=hc_stock_save_start_rom(s,rom,target,program_path,args,envp);
 if(result){if(s->phase!=HC_STOCK_RUNNING){s->program=s->core=s->config=NULL;if(s->report_read>=0)(void)close_owned(&s->report_read);if(s->report_write<0&&s->report_read<0)s->report_required=0;}return -1;}
 if(!reviewed_files_ok(s)){s->rom_fault=1;errno=EIO;return -1;}return 0;
}
int hc_stock_save_signal(HCStockSaveSession *s,int sig){
 if(!s||s->phase!=HC_STOCK_RUNNING||(sig!=SIGTERM&&sig!=SIGKILL)){errno=EINVAL;return -1;}
 /* A terminated but unreaped child can still accept kill(2). Reap it first
  * so an already-finished session cannot be treated as a requested quit.
  * The remaining poll/signal race still requires independent save evidence. */
 int status=0,live=hc_stock_save_poll(s,&status);
 if(live!=0){if(live>0)errno=ECHILD;return -1;}
 if(hc_child_signal(&s->child,sig))return -1;s->requested=sig==SIGTERM;return 0;
}
int hc_stock_save_poll(HCStockSaveSession *s,int *status){
 if(!s||s->phase!=HC_STOCK_RUNNING||!status){errno=EINVAL;return -1;}
 int r=hc_child_poll(&s->child,status);if(r<0){
  /* ECHILD or another lost-child result is not proof that the owned game
   * stopped. Retain the session and its save lock for external inspection. */
  if(s->child.pid==-1&&!s->child.reaped_pending)s->child_wait_unknown=1;
  s->phase=HC_STOCK_FAILED;return -1;
 }
 if(r==1){if(s->report_required){
   char report[2];ssize_t n;do n=read(s->report_read,report,sizeof report);while(n<0&&errno==EINTR);
   if(n!=1)s->rom_fault=1;
   else {char extra;ssize_t tail;do tail=read(s->report_read,&extra,1);while(tail<0&&errno==EINTR);if(tail!=0)s->rom_fault=1;else{s->report_code=(unsigned char)report[0];if(report[0]!='S'&&report[0]!='N')s->rom_fault=1;}}
   if(close_owned(&s->report_read))s->rom_fault=1;
  }
  if(s->rom&&hc_verified_launch_recheck(s->rom))s->rom_fault=1;
  if(s->program&&!reviewed_files_ok(s))s->rom_fault=1;
  if(s->report_required&&!s->rom_fault&&s->requested&&WIFEXITED(*status)&&WEXITSTATUS(*status)==0)
   s->phase=s->report_code=='N'?HC_STOCK_REAPED_NO_SRAM:HC_STOCK_REAPED_CLEAN;
  else s->phase=HC_STOCK_REAPED_FAILED;}return r;
}
int hc_stock_save_validate_no_sram(HCStockSaveSession *s){
 struct stat dir,current;
 if(!s||s->phase!=HC_STOCK_REAPED_NO_SRAM||s->report_code!='N'||!s->report_required||!s->stage_snapshot_taken||s->stage_dir<0){errno=EINVAL;return -1;}
 if(!stage_private(s->stage_dir,&dir)||(s->rom&&hc_verified_launch_recheck(s->rom))||(s->program&&!reviewed_files_ok(s)))goto bad;
 if(s->stage_was_present){
  if(fstatat(s->stage_dir,s->stage_name,&current,AT_SYMLINK_NOFOLLOW)||!same_file(&s->stage_before,&current))goto bad;
 }else if(fstatat(s->stage_dir,s->stage_name,&current,AT_SYMLINK_NOFOLLOW)==0||errno!=ENOENT)goto bad;
 return 0;
bad:
 s->phase=HC_STOCK_FAILED;errno=EIO;return -1;
}
int hc_stock_save_publish_stage(HCStockSaveSession *s){
 struct stat dir,before,held,after,named;int fd=-1,result=-1,saved=EIO;unsigned char *bytes=NULL;
 if(!s||s->phase!=HC_STOCK_REAPED_CLEAN||s->stage_dir<0){errno=EINVAL;return -1;}
 if((s->rom&&hc_verified_launch_recheck(s->rom))||(s->program&&!reviewed_files_ok(s))){s->phase=HC_STOCK_FAILED;errno=EIO;return -1;}
 s->phase=HC_STOCK_FAILED;
 if(!stage_private(s->stage_dir,&dir)||fstatat(s->stage_dir,s->stage_name,&before,AT_SYMLINK_NOFOLLOW)||
    !S_ISREG(before.st_mode)||before.st_uid!=geteuid()||before.st_nlink!=1||(before.st_mode&0022)||before.st_size!=(off_t)s->stage_size||
    !s->stage_snapshot_taken||(s->stage_was_present&&same_stage_version(&s->stage_before,&before)))goto done;
 fd=openat(s->stage_dir,s->stage_name,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(fd<0)goto done;
 if(fstat(fd,&held)||!same_file(&before,&held))goto done;
 bytes=malloc(s->stage_size);if(!bytes)goto done;
 size_t pos=0;while(pos<s->stage_size){ssize_t n=pread(fd,bytes+pos,s->stage_size-pos,(off_t)pos);if(n<0&&errno==EINTR)continue;if(n<=0)goto done;pos+=(size_t)n;}
 if(fsync(fd)||fstat(fd,&after)||!same_file(&held,&after)||fstatat(s->stage_dir,s->stage_name,&named,AT_SYMLINK_NOFOLLOW)||!same_file(&held,&named)||!stage_private(s->stage_dir,&dir))goto done;
 result=hc_autosave_target_write(&s->target,s->identity,bytes,s->stage_size);saved=errno;
 if(!result)s->phase=HC_STOCK_PUBLISHED;
done:
 if(fd>=0&&close(fd)&&!result){result=-2;saved=EIO;s->phase=HC_STOCK_FAILED;}
 if(!result){s->published_bytes=bytes;s->published_length=s->stage_size;bytes=NULL;}
 free(bytes);if(result)errno=saved;return result;
}
int hc_stock_save_close(HCStockSaveSession *s){
 if(!s||s->phase==HC_STOCK_EMPTY||s->phase==HC_STOCK_CLOSED||s->child.pid!=-1||s->child_wait_unknown||s->child.reaped_pending){errno=EBUSY;return -1;}
 if(s->child.input>=0&&close_owned(&s->child.input))return -1;
 if(s->target.ready&&hc_autosave_target_close(&s->target))return -1;
 /* Keep a still-open descriptor quarantined until cleanup succeeds. */
 int *fds[]={&s->stage_dir,&s->report_read,&s->report_write,&s->screenshot_write};
 for(size_t i=0;i<sizeof fds/sizeof fds[0];i++)if(*fds[i]>=0&&close_owned(fds[i]))return -1;
 free(s->initial_bytes);s->initial_bytes=NULL;s->initial_length=0;s->initial_valid=s->initial_present=0;free(s->published_bytes);s->published_bytes=NULL;s->published_length=0;s->phase=HC_STOCK_CLOSED;return 0;
}
