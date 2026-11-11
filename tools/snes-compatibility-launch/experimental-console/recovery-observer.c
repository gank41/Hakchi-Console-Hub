#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#include "recovery-observer.h"
#include "screenshot_png.h"
#include "screenshot-session-names.h"
#include "save-directory-lock.h"
#include "playtime.h"
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* Exclusive access and independently authenticated open directory handles
 * are prerequisites, not facts this collector can infer. */
int hc_recovery_observe(int dir,const char *name,const char *game,const char *rom,const uint8_t token[16],uint64_t epoch,const HCSessionExpected *regions,size_t count,size_t index,HCRecoveryObservation *out){
 if(!out||!regions||!count||count>16||index>=count||!token||!game||!rom){errno=EINVAL;return -1;}
 HCRecoveryObservation result={0};HCIV2Entry after[16]={{0}};size_t after_count=0;struct stat parent_before,parent_after,file_before,file_after,named;int fd=-1,ok=0;
 if(fstat(regions[index].parent,&parent_before)||!S_ISDIR(parent_before.st_mode))goto done;
 if(hc_binding_inventory(dir,name,game,rom,token,epoch,regions,count,index,result.entries,16,&result.entry_count))goto done;
 fd=openat(dir,name,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(fd<0)goto done;
 if(fstat(fd,&file_before)||!S_ISREG(file_before.st_mode)||file_before.st_uid!=geteuid()||(file_before.st_mode&0777)!=0600||file_before.st_nlink!=1||file_before.st_size<=0||file_before.st_size>=(off_t)sizeof result.descriptor)goto done;
 result.descriptor_length=(size_t)file_before.st_size;size_t got=0;
 while(got<result.descriptor_length){ssize_t n=read(fd,result.descriptor+got,result.descriptor_length-got);if(n<0&&errno==EINTR)continue;if(n<=0)goto done;got+=(size_t)n;}
 if(fstat(fd,&file_after)||fstatat(dir,name,&named,AT_SYMLINK_NOFOLLOW)||file_after.st_dev!=file_before.st_dev||file_after.st_ino!=file_before.st_ino||file_after.st_size!=file_before.st_size||named.st_dev!=file_before.st_dev||named.st_ino!=file_before.st_ino)goto done;
 /* Reconstruct the only descriptor accepted for the held parent handles. */
 char expected[20000],hex[33];for(size_t i=0;i<16;i++)snprintf(hex+2*i,3,"%02x",token[i]);
 int n=snprintf(expected,sizeof expected,"HC-BINDING-1\n%s\n%s\n%s\n%" PRIu64 "\n%zu\n",game,rom,hex,epoch,count);if(n<0||(size_t)n>=sizeof expected)goto done;size_t len=(size_t)n;
 for(size_t i=0;i<count;i++){struct stat s;if(fstat(regions[i].parent,&s))goto done;n=snprintf(expected+len,sizeof expected-len,"%u %" PRIuMAX " %" PRIuMAX " %s\n",regions[i].type,(uintmax_t)s.st_dev,(uintmax_t)s.st_ino,regions[i].identity);if(n<0||(size_t)n>=sizeof expected-len)goto done;len+=(size_t)n;}
 if(len!=result.descriptor_length||memcmp(expected,result.descriptor,len))goto done;
 if(hc_binding_inventory(dir,name,game,rom,token,epoch,regions,count,index,after,16,&after_count)||after_count!=result.entry_count)goto done;
 for(size_t i=0;i<after_count;i++)if(strcmp(after[i].session,result.entries[i].session)||strcmp(after[i].workspace,result.entries[i].workspace)||strcmp(after[i].region,result.entries[i].region)||after[i].kind!=result.entries[i].kind||after[i].workspace_present!=result.entries[i].workspace_present)goto done;
 if(fstat(regions[index].parent,&parent_after)||parent_before.st_dev!=parent_after.st_dev||parent_before.st_ino!=parent_after.st_ino||parent_before.st_uid!=parent_after.st_uid||parent_before.st_mode!=parent_after.st_mode)goto done;
 result.device=(uint64_t)parent_before.st_dev;result.inode=(uint64_t)parent_before.st_ino;ok=1;
 done: if(fd>=0&&close(fd))ok=0;if(!ok){errno=EIO;return -1;}*out=result;return 0;
}

#include "arguments.h"
/* No mkdir: reporting must never initialize a game profile. */
static int open_existing_dir(int parent,const char *name,uid_t uid,int private_mode){
 struct stat before,after;int fd=-1;
 if(fstatat(parent,name,&before,AT_SYMLINK_NOFOLLOW)||!S_ISDIR(before.st_mode)||before.st_uid!=uid||
    (private_mode?(before.st_mode&0777)!=0700:(before.st_mode&0022)!=0)){errno=EACCES;return -1;}
 fd=openat(parent,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return -1;
 if(fstat(fd,&after)||before.st_dev!=after.st_dev||before.st_ino!=after.st_ino||before.st_mode!=after.st_mode||before.st_uid!=after.st_uid){int saved=errno?errno:EIO;close(fd);errno=saved;return -1;}
 return fd;
}
int hc_recovery_lock_game(int profiles,uid_t uid,const HCLaunchRequest *req,uint64_t device,uint64_t inode){
 int held[4]={-1,-1,-1,-1},lock=-1;struct stat st,named;unsigned char wire[HC_LAUNCH_REQUEST_SIZE];
 if(!req||uid!=geteuid()||!inode||hc_launch_request_encode(req,wire)){errno=EINVAL;return -1;}
 held[0]=open_existing_dir(profiles,req->game,uid,0);if(held[0]<0)goto done;
 held[1]=open_existing_dir(held[0],"hakchi",uid,1);if(held[1]<0)goto done;
 held[2]=open_existing_dir(held[1],HC_COMPATIBILITY_ENGINE_ID,uid,1);if(held[2]<0)goto done;
 held[3]=open_existing_dir(held[2],req->digest,uid,1);if(held[3]<0)goto done;
 if(fstat(held[3],&st)||(uint64_t)st.st_dev!=device||(uint64_t)st.st_ino!=inode){errno=ESTALE;goto done;}
 lock=hc_save_directory_lock(held[3],uid);if(lock<0)goto done;
 const char *names[]={req->game,"hakchi",HC_COMPATIBILITY_ENGINE_ID,req->digest};
 for(size_t i=0;i<4;i++){int p=i?held[i-1]:profiles;if(fstat(held[i],&st)||fstatat(p,names[i],&named,AT_SYMLINK_NOFOLLOW)||st.st_dev!=named.st_dev||st.st_ino!=named.st_ino||st.st_mode!=named.st_mode||st.st_uid!=named.st_uid){int saved=errno;close(lock);lock=-1;errno=saved?saved:EIO;break;}}
 done: {int saved=errno;for(int i=3;i>=0;i--)if(held[i]>=0&&close(held[i])&&lock>=0){close(lock);lock=-1;saved=EIO;}if(lock<0)errno=saved?saved:EIO;return lock;}
}
/* Select only the exact session's retained-image binding when present. An
 * invalid or incomplete binding is refused by hc_recovery_observe; it must
 * never silently fall back to the battery-only binding. */
static int game_regions(int parent,const char *root,const HCLaunchRequest *req,char paths[3][1024],char binding[47],HCSessionExpected regions[3],size_t *count){
 HCScreenshotSessionNames names;struct stat st;static const char hex[]="0123456789abcdef";
 if(hc_screenshot_session_names(req->session,&names))return -1;
 const char *leaf[]={"battery.srm","battery.rtc",names.retained_file};
 for(size_t i=0;i<3;i++){
  int n=snprintf(paths[i],1024,"%s/%s/hakchi/%s/%s/%s",root,req->game,HC_COMPATIBILITY_ENGINE_ID,req->digest,leaf[i]);
  if(n<=0||n>=1024){errno=EINVAL;return -1;}
  regions[i]=(HCSessionExpected){parent,paths[i],i==2?100u:(unsigned)i};
 }
 if(!fstatat(parent,names.retained_binding,&st,AT_SYMLINK_NOFOLLOW)){
  memcpy(binding,names.retained_binding,sizeof names.retained_binding);*count=3;return 0;
 }
 if(errno!=ENOENT)return -1;
 memcpy(binding,"bind-",5);for(size_t i=0;i<16;i++){binding[5+2*i]=hex[req->session[i]>>4];binding[6+2*i]=hex[req->session[i]&15];}binding[37]=0;*count=2;return 0;
}
static int same_observation(const HCRecoveryObservation *,const HCRecoveryObservation *);
int hc_recovery_observe_game(int profiles,const char *root,uid_t uid,const HCLaunchRequest *req,size_t index,HCRecoveryObservation *out){
 unsigned char wire[HC_LAUNCH_REQUEST_SIZE];int held[4]={-1,-1,-1,-1},named=-1,ok=0;struct stat a,b;char paths[3][1024],binding[47];HCRecoveryObservation observed;HCSessionExpected regions[3];size_t region_count=0;
 if(!out||!root||root[0]!='/'||strnlen(root,1024)>=1024||!req||index>=2||uid!=geteuid()||hc_launch_request_encode(req,wire)){errno=EINVAL;return -1;}
 if(fstat(profiles,&a)||!S_ISDIR(a.st_mode)||a.st_uid!=uid||(a.st_mode&0022))goto done;
 named=open(root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(named<0||fstat(named,&b)||a.st_dev!=b.st_dev||a.st_ino!=b.st_ino)goto done;
 held[0]=open_existing_dir(profiles,req->game,uid,0);if(held[0]<0)goto done;
 held[1]=open_existing_dir(held[0],"hakchi",uid,1);if(held[1]<0)goto done;
 held[2]=open_existing_dir(held[1],HC_COMPATIBILITY_ENGINE_ID,uid,1);if(held[2]<0)goto done;
 held[3]=open_existing_dir(held[2],req->digest,uid,1);if(held[3]<0)goto done;
 if(game_regions(held[3],root,req,paths,binding,regions,&region_count)||
    hc_recovery_observe(held[3],binding,req->game,req->digest,req->session,req->epoch,regions,region_count,index,&observed))goto done;
 const char *names[]={req->game,"hakchi",HC_COMPATIBILITY_ENGINE_ID,req->digest};
 for(size_t i=0;i<4;i++){int parent=i?held[i-1]:profiles;if(fstat(held[i],&a)||fstatat(parent,names[i],&b,AT_SYMLINK_NOFOLLOW)||!S_ISDIR(b.st_mode)||a.st_dev!=b.st_dev||a.st_ino!=b.st_ino||a.st_mode!=b.st_mode||a.st_uid!=b.st_uid)goto done;}
 if(fstat(profiles,&a)||fstat(named,&b)||a.st_dev!=b.st_dev||a.st_ino!=b.st_ino)goto done;ok=1;
 done: {int saved=errno;for(int i=3;i>=0;i--)if(held[i]>=0&&close(held[i]))ok=0;if(named>=0&&close(named))ok=0;if(!ok){errno=saved?saved:EIO;return -1;}*out=observed;return 0;}
}

/* Offline-only adapter. The caller independently authenticates the original
 * state and selected session, stops all writers and excludes path mutation. */
int hc_recovery_restore_game(int profiles,const char *root,uid_t uid,const HCLaunchRequest *req,size_t index,const char *workspace,HCRecoveryOriginal original,const void *bytes,size_t length){
 int held[4]={-1,-1,-1,-1},result=-1,modified=0;struct stat a,b;HCRecoveryObservation observation,rechecked;char paths[3][1024],binding[47];HCSessionExpected regions[3];size_t region_count=0;
 if(!workspace||strnlen(workspace,44)!=43||!bytes||!length||!req||!root||index>=2||(original!=HC_RECOVERY_ORIGINAL_PRESENT&&original!=HC_RECOVERY_ORIGINAL_ABSENT)){errno=EINVAL;return -1;}
 if(hc_recovery_observe_game(profiles,root,uid,req,index,&observation))return -1;
 const char *region=index?"battery.rtc":"battery.srm";size_t matches=0;
 for(size_t i=0;i<observation.entry_count;i++)if(!strcmp(observation.entries[i].workspace,workspace)){
  if(strcmp(observation.entries[i].region,region)||!observation.entries[i].workspace_present){errno=EINVAL;return -1;}matches++;
 }
 if(matches!=1){errno=ENOENT;return -1;}
 held[0]=open_existing_dir(profiles,req->game,uid,0);if(held[0]<0)goto done;
 held[1]=open_existing_dir(held[0],"hakchi",uid,1);if(held[1]<0)goto done;
 held[2]=open_existing_dir(held[1],HC_COMPATIBILITY_ENGINE_ID,uid,1);if(held[2]<0)goto done;
 held[3]=open_existing_dir(held[2],req->digest,uid,1);if(held[3]<0)goto done;
 if(fstat(held[3],&a)||(uint64_t)a.st_dev!=observation.device||(uint64_t)a.st_ino!=observation.inode){errno=EIO;goto done;}
 const char *names[]={req->game,"hakchi",HC_COMPATIBILITY_ENGINE_ID,req->digest};
 for(size_t i=0;i<4;i++){int parent=i?held[i-1]:profiles;if(fstat(held[i],&a)||fstatat(parent,names[i],&b,AT_SYMLINK_NOFOLLOW)||!S_ISDIR(b.st_mode)||a.st_dev!=b.st_dev||a.st_ino!=b.st_ino||a.st_mode!=b.st_mode||a.st_uid!=b.st_uid){errno=EIO;goto done;}}
 if(game_regions(held[3],root,req,paths,binding,regions,&region_count)||
    hc_recovery_observe(held[3],binding,req->game,req->digest,req->session,req->epoch,regions,region_count,index,&rechecked)||!same_observation(&observation,&rechecked)){errno=EIO;goto done;}
 if(original==HC_RECOVERY_ORIGINAL_PRESENT)result=hc_binding_restore_previous(held[3],binding,req->game,req->digest,req->session,req->epoch,regions,region_count,index,workspace,bytes,length);
 else result=hc_binding_restore_absent(held[3],binding,req->game,req->digest,req->session,req->epoch,regions,region_count,index,workspace,bytes,length);
 if(result==0||result==-2)modified=1;
 done: {int saved=errno;for(int i=3;i>=0;i--)if(held[i]>=0&&close(held[i])){if(result==0)result=-1;saved=EIO;}if(result<0&&modified)result=-2;errno=saved;return result;}
}

/* The two observations bracket the file read. Callers must still establish
 * stopped writers and exclusive control; matching snapshots are not proof. */
static int same_observation(const HCRecoveryObservation *a,const HCRecoveryObservation *b){
 if(a->device!=b->device||a->inode!=b->inode||a->descriptor_length!=b->descriptor_length||a->entry_count!=b->entry_count||memcmp(a->descriptor,b->descriptor,a->descriptor_length))return 0;
 for(size_t i=0;i<a->entry_count;i++)if(strcmp(a->entries[i].session,b->entries[i].session)||strcmp(a->entries[i].workspace,b->entries[i].workspace)||strcmp(a->entries[i].region,b->entries[i].region)||a->entries[i].kind!=b->entries[i].kind||a->entries[i].workspace_present!=b->entries[i].workspace_present)return 0;
 return 1;
}
/* Snapshot metadata is checked around both the read and the journal reread;
 * it supplements, but cannot replace, the caller's exclusive-access duty. */
static int same_staged_file(const struct stat *a,const struct stat *b){
 if(a->st_dev!=b->st_dev||a->st_ino!=b->st_ino||a->st_size!=b->st_size||a->st_uid!=b->st_uid||a->st_mode!=b->st_mode||a->st_nlink!=b->st_nlink)return 0;
#ifdef __APPLE__
 return a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec&&a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec&&a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec&&a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec;
#else
 return a->st_mtim.tv_sec==b->st_mtim.tv_sec&&a->st_mtim.tv_nsec==b->st_mtim.tv_nsec&&a->st_ctim.tv_sec==b->st_ctim.tv_sec&&a->st_ctim.tv_nsec==b->st_ctim.tv_nsec;
#endif
}
static int read_retained_png(int dir,const char *binding,const char *game,const char *rom,const uint8_t token[16],uint64_t epoch,const HCSessionExpected *regions,size_t count,size_t index,int pending,void *output,size_t capacity,size_t *length){
 HCRecoveryObservation first,second;struct stat parent,before,after,named;int fd=-1,ok=0;unsigned char *bytes=NULL;size_t size=0;
 if(!regions||index>=count||regions[index].type!=100||!regions[index].identity||!output||!length||!capacity){errno=EINVAL;return -1;}
 if(hc_recovery_observe(dir,binding,game,rom,token,epoch,regions,count,index,&first))goto done;
 const char *base=strrchr(regions[index].identity,'/');if(!base||!base[1]){errno=EINVAL;goto done;}base++;
 unsigned matches=0;for(size_t i=0;i<first.entry_count;i++)if(!strcmp(first.entries[i].region,base)){
  if(first.entries[i].kind!=HCIV2_FINAL||!first.entries[i].workspace_present){errno=EINVAL;goto done;}matches++;
 }
 if(pending ? matches!=1 : first.entry_count!=0){errno=EINVAL;goto done;}
 int parentfd=regions[index].parent;
 if(fstat(parentfd,&parent)||!S_ISDIR(parent.st_mode)||parent.st_uid!=geteuid()||(parent.st_mode&0777)!=0700)goto done;
 fd=openat(parentfd,base,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(fd<0)goto done;
 if(fstat(fd,&before)||fstatat(parentfd,base,&named,AT_SYMLINK_NOFOLLOW)||!S_ISREG(before.st_mode)||before.st_uid!=geteuid()||
    (before.st_mode&0777)!=0600||before.st_nlink!=1||before.st_size<57||before.st_size>8*1024*1024||before.st_size>(off_t)capacity||!same_staged_file(&before,&named)){errno=EINVAL;goto done;}
 size=(size_t)before.st_size;bytes=malloc(size);if(!bytes)goto done;
 for(size_t pos=0;pos<size;){ssize_t n=pread(fd,bytes+pos,size-pos,(off_t)pos);if(n<0&&errno==EINTR)continue;if(n<=0){errno=EIO;goto done;}pos+=(size_t)n;}
 if(hc_screenshot_png(bytes,size)||fstat(fd,&after)||!same_staged_file(&before,&after)||fstatat(parentfd,base,&named,AT_SYMLINK_NOFOLLOW)||!same_staged_file(&before,&named))goto done;
 if(hc_recovery_observe(dir,binding,game,rom,token,epoch,regions,count,index,&second)||!same_observation(&first,&second)||
    fstat(fd,&after)||!same_staged_file(&before,&after)||fstatat(parentfd,base,&named,AT_SYMLINK_NOFOLLOW)||!same_staged_file(&before,&named))goto done;
 ok=1;
done: {int saved=errno;if(fd>=0&&close(fd))ok=0;if(ok){memcpy(output,bytes,size);*length=size;}free(bytes);if(!ok){errno=saved?saved:EIO;return -1;}return 0;}
}
int hc_recovery_read_retained_png(int dir,const char *binding,const char *game,const char *rom,const uint8_t token[16],uint64_t epoch,const HCSessionExpected *regions,size_t count,size_t index,void *output,size_t capacity,size_t *length){
 return read_retained_png(dir,binding,game,rom,token,epoch,regions,count,index,1,output,capacity,length);
}
int hc_recovery_collect_retained_png(int dir,const char *binding,const char *game,const char *rom,const uint8_t token[16],uint64_t epoch,const HCSessionExpected *regions,size_t count,size_t index,HCRecoveryObservation *observation,void *output,size_t capacity,size_t *length){
 HCRecoveryObservation before,after;unsigned char *copy=NULL;size_t bytes=0;int result=-1;
 if(!observation||!output||!length||!capacity){errno=EINVAL;return -1;}
 size_t limit=capacity<8u*1024u*1024u?capacity:8u*1024u*1024u;
 copy=malloc(limit);if(!copy)return -1;
 if(hc_recovery_observe(dir,binding,game,rom,token,epoch,regions,count,index,&before)||
    hc_recovery_read_retained_png(dir,binding,game,rom,token,epoch,regions,count,index,copy,limit,&bytes)||
    hc_recovery_observe(dir,binding,game,rom,token,epoch,regions,count,index,&after)||!same_observation(&before,&after))goto done;
 *observation=after;memcpy(output,copy,bytes);*length=bytes;result=0;
done: {int saved=errno;free(copy);if(result)errno=saved?saved:EIO;return result;}
}
int hc_recovery_collect_session_retained(int dir,const char *game,const char *rom,const uint8_t token[16],uint64_t epoch,const HCSessionExpected *regions,size_t count,size_t index,HCRecoveryObservation *observation,void *output,size_t capacity,size_t *length){
 HCScreenshotSessionNames names;
 if(!regions||index>=count||!regions[index].identity||strnlen(regions[index].identity,1024)>=1024||hc_screenshot_session_names(token,&names)){errno=EINVAL;return -1;}
 const char *base=strrchr(regions[index].identity,'/');
 if(!base||strcmp(base+1,names.retained_file)){errno=EINVAL;return -1;}
 return hc_recovery_collect_retained_png(dir,names.retained_binding,game,rom,token,epoch,regions,count,index,observation,output,capacity,length);
}
int hc_recovery_collect_session_retired_image(int dir,const char *game,const char *rom,const uint8_t token[16],uint64_t epoch,const HCSessionExpected *regions,size_t count,size_t index,HCRecoveryObservation *observation,void *output,size_t capacity,size_t *length){
 HCScreenshotSessionNames names;HCRecoveryObservation before,after;unsigned char *copy=NULL;size_t bytes=0;int ok=0;
 if(!regions||index>=count||!regions[index].identity||strnlen(regions[index].identity,1024)>=1024||!observation||!output||!length||!capacity||hc_screenshot_session_names(token,&names)){errno=EINVAL;return -1;}
 const char *base=strrchr(regions[index].identity,'/');if(!base||strcmp(base+1,names.retained_file)){errno=EINVAL;return -1;}
 size_t limit=capacity<8u*1024u*1024u?capacity:8u*1024u*1024u;copy=malloc(limit);if(!copy)return -1;
 if(hc_recovery_observe(dir,names.retained_binding,game,rom,token,epoch,regions,count,index,&before)||before.entry_count||
    read_retained_png(dir,names.retained_binding,game,rom,token,epoch,regions,count,index,0,copy,limit,&bytes)||
    hc_recovery_observe(dir,names.retained_binding,game,rom,token,epoch,regions,count,index,&after)||!same_observation(&before,&after))goto done;
 ok=1;
done: {int saved=errno;if(ok){*observation=after;memcpy(output,copy,bytes);*length=bytes;}free(copy);if(!ok){errno=saved?saved:EIO;return -1;}return 0;}
}
int hc_recovery_collect_session_retained_state(int dir,const char *game,const char *rom,const uint8_t token[16],uint64_t epoch,const HCSessionExpected *regions,size_t count,size_t index,HCRecoveryObservation *observation,void *output,size_t capacity,size_t *length){
 HCScreenshotSessionNames names;HCRecoveryObservation before,after;struct stat first,last,named;int fd=-1,ok=0;unsigned char *bytes=NULL;size_t size=0;
 char base_name[45];static const char hex[]="0123456789abcdef";
 if(!regions||index>=count||regions[index].type!=101||!regions[index].identity||!observation||!output||!length||!capacity||hc_screenshot_session_names(token,&names)){errno=EINVAL;return -1;}
 memcpy(base_name,"state-",6);for(size_t i=0;i<16;i++){base_name[6+2*i]=hex[token[i]>>4];base_name[7+2*i]=hex[token[i]&15];}memcpy(base_name+38,".state",7);
 const char *base=strrchr(regions[index].identity,'/');if(!base||strcmp(base+1,base_name)){errno=EINVAL;return -1;}
 if(hc_recovery_observe(dir,names.retained_binding,game,rom,token,epoch,regions,count,index,&before))goto done;
 unsigned matches=0;for(size_t i=0;i<before.entry_count;i++)if(!strcmp(before.entries[i].region,base_name)){
  if(before.entries[i].kind!=HCIV2_FINAL||!before.entries[i].workspace_present){errno=EINVAL;goto done;}matches++;
 }
 if(matches!=1){errno=EINVAL;goto done;}
 fd=openat(regions[index].parent,base_name,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(fd<0)goto done;
 if(fstat(fd,&first)||fstatat(regions[index].parent,base_name,&named,AT_SYMLINK_NOFOLLOW)||!S_ISREG(first.st_mode)||first.st_uid!=geteuid()||(first.st_mode&0777)!=0600||first.st_nlink!=1||first.st_size<=0||first.st_size>16*1024*1024||first.st_size>(off_t)capacity||!same_staged_file(&first,&named)){errno=EINVAL;goto done;}
 size=(size_t)first.st_size;bytes=malloc(size);if(!bytes)goto done;
 for(size_t pos=0;pos<size;){ssize_t n=pread(fd,bytes+pos,size-pos,(off_t)pos);if(n<0&&errno==EINTR)continue;if(n<=0){errno=EIO;goto done;}pos+=(size_t)n;}
 if(fstat(fd,&last)||!same_staged_file(&first,&last)||fstatat(regions[index].parent,base_name,&named,AT_SYMLINK_NOFOLLOW)||!same_staged_file(&first,&named)||
    hc_recovery_observe(dir,names.retained_binding,game,rom,token,epoch,regions,count,index,&after)||!same_observation(&before,&after)||
    fstat(fd,&last)||!same_staged_file(&first,&last)||fstatat(regions[index].parent,base_name,&named,AT_SYMLINK_NOFOLLOW)||!same_staged_file(&first,&named))goto done;
 ok=1;
done: {int saved=errno;if(fd>=0&&close(fd))ok=0;if(ok){*observation=after;memcpy(output,bytes,size);*length=size;}free(bytes);if(!ok){errno=saved?saved:EIO;return -1;}return 0;}
}
typedef int (*HCCheckpointCollector)(int,const char *,const char *,const uint8_t[16],uint64_t,const HCSessionExpected *,size_t,size_t,HCRecoveryObservation *,void *,size_t,size_t *);
static int collect_game_checkpoint(int profiles,const char *root,uid_t uid,const HCLaunchRequest *req,int paired,int image,HCCheckpointCollector collector,HCRecoveryObservation *out,void *output,size_t capacity,size_t *length){
 unsigned char wire[HC_LAUNCH_REQUEST_SIZE],*copy=NULL;int held[4]={-1,-1,-1,-1},named=-1,ok=0;struct stat a,b;HCRecoveryObservation observed;size_t size=0;
 char paths[4][1024],token[33];static const char hex[]="0123456789abcdef";
 if(!root||root[0]!='/'||strnlen(root,1024)>=1024||!req||(paired!=0&&paired!=1)||uid!=geteuid()||!out||!output||!capacity||!length||hc_launch_request_encode(req,wire)){errno=EINVAL;return -1;}
 if(fstat(profiles,&a)||!S_ISDIR(a.st_mode)||a.st_uid!=uid||(a.st_mode&0022))goto done;
 named=open(root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(named<0||fstat(named,&b)||a.st_dev!=b.st_dev||a.st_ino!=b.st_ino)goto done;
 held[0]=open_existing_dir(profiles,req->game,uid,0);if(held[0]<0)goto done;
 held[1]=open_existing_dir(held[0],"hakchi",uid,1);if(held[1]<0)goto done;
 held[2]=open_existing_dir(held[1],HC_COMPATIBILITY_ENGINE_ID,uid,1);if(held[2]<0)goto done;
 held[3]=open_existing_dir(held[2],req->digest,uid,1);if(held[3]<0)goto done;
 for(size_t i=0;i<16;i++){token[2*i]=hex[req->session[i]>>4];token[2*i+1]=hex[req->session[i]&15];}token[32]=0;
 char basename[4][64]={{0}};strcpy(basename[0],"battery.srm");strcpy(basename[1],"battery.rtc");
 if(snprintf(basename[2],sizeof basename[2],"state-%s.state",token)!=44||snprintf(basename[3],sizeof basename[3],"shot-%s.png",token)!=41){errno=EINVAL;goto done;}
 for(size_t i=0;i<4;i++){int n=snprintf(paths[i],sizeof paths[i],"%s/%s/hakchi/%s/%s/%s",root,req->game,HC_COMPATIBILITY_ENGINE_ID,req->digest,basename[i]);if(n<=0||(size_t)n>=sizeof paths[i]){errno=EINVAL;goto done;}}
 HCSessionExpected regions[]={{held[3],paths[0],0},{held[3],paths[1],1},{held[3],paths[2],101},{held[3],paths[3],100}};
 if(image&&!paired)regions[2]=regions[3];
 size_t max=image?8u*1024u*1024u:16u*1024u*1024u,limit=capacity<max?capacity:max;copy=malloc(limit);if(!copy)goto done;
 size_t index=image&&paired?3:2;
 if(collector(held[3],req->game,req->digest,req->session,req->epoch,regions,paired?4:3,index,&observed,copy,limit,&size))goto done;
 const char *names[]={req->game,"hakchi",HC_COMPATIBILITY_ENGINE_ID,req->digest};
 for(size_t i=0;i<4;i++){int parent=i?held[i-1]:profiles;if(fstat(held[i],&a)||fstatat(parent,names[i],&b,AT_SYMLINK_NOFOLLOW)||!S_ISDIR(b.st_mode)||a.st_dev!=b.st_dev||a.st_ino!=b.st_ino||a.st_mode!=b.st_mode||a.st_uid!=b.st_uid)goto done;}
 if(fstat(profiles,&a)||fstat(named,&b)||a.st_dev!=b.st_dev||a.st_ino!=b.st_ino)goto done;ok=1;
done: {int saved=errno;for(int i=3;i>=0;i--)if(held[i]>=0&&close(held[i]))ok=0;if(named>=0&&close(named))ok=0;if(ok){*out=observed;memcpy(output,copy,size);*length=size;}free(copy);if(!ok){errno=saved?saved:EIO;return -1;}return 0;}
}
int hc_recovery_collect_game_state(int profiles,const char *root,uid_t uid,const HCLaunchRequest *req,int paired,HCRecoveryObservation *out,void *output,size_t capacity,size_t *length){return collect_game_checkpoint(profiles,root,uid,req,paired,0,hc_recovery_collect_session_retained_state,out,output,capacity,length);}
int hc_recovery_collect_game_image(int profiles,const char *root,uid_t uid,const HCLaunchRequest *req,int paired,HCRecoveryObservation *out,void *output,size_t capacity,size_t *length){return collect_game_checkpoint(profiles,root,uid,req,paired,1,hc_recovery_collect_session_retained,out,output,capacity,length);}
int hc_recovery_collect_game_retired_image(int profiles,const char *root,uid_t uid,const HCLaunchRequest *req,int paired,HCRecoveryObservation *out,void *output,size_t capacity,size_t *length){return collect_game_checkpoint(profiles,root,uid,req,paired,1,hc_recovery_collect_session_retired_image,out,output,capacity,length);}
int hc_recovery_collect_game_state_archive(int profiles,const char *root,uid_t uid,const HCLaunchRequest *req,HCRecoveryObservation *out,void *output,size_t capacity,size_t *length){
 unsigned char wire[HC_LAUNCH_REQUEST_SIZE],again[4096],*bytes=NULL;int held[7]={-1,-1,-1,-1,-1,-1,-1},named=-1,fd=-1,ok=0;
 struct stat a,b,first,last;HCRecoveryObservation before,after;size_t size=0;char token[33],workspace[44],path[1024];static const char hex[]="0123456789abcdef";
 if(!root||root[0]!='/'||strnlen(root,1024)>=1024||!req||uid!=geteuid()||!out||!output||!capacity||!length||hc_launch_request_encode(req,wire)){errno=EINVAL;return -1;}
 if(fstat(profiles,&a)||!S_ISDIR(a.st_mode)||a.st_uid!=uid||(a.st_mode&0022))goto done;
 named=open(root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(named<0||fstat(named,&b)||a.st_dev!=b.st_dev||a.st_ino!=b.st_ino)goto done;
 for(size_t i=0;i<16;i++){token[2*i]=hex[req->session[i]>>4];token[2*i+1]=hex[req->session[i]&15];}token[32]=0;
 if(snprintf(workspace,sizeof workspace,"checkpoint-%s",token)!=(int)(sizeof workspace-1))goto done;
 const char *names[]={req->game,"hakchi",HC_COMPATIBILITY_ENGINE_ID,req->digest,"sessions",workspace,"state-archive"};
 for(size_t i=0;i<7;i++){held[i]=open_existing_dir(i?held[i-1]:profiles,names[i],uid,i?1:0);if(held[i]<0)goto done;}
 int n=snprintf(path,sizeof path,"%s/%s/hakchi/%s/%s/sessions/%s/state-archive/state-captured",root,req->game,HC_COMPATIBILITY_ENGINE_ID,req->digest,workspace);
 if(n<=0||(size_t)n>=sizeof path){errno=EINVAL;goto done;}
 HCSessionExpected region={held[6],path,107};
 if(hc_recovery_observe(held[6],"state-binding",req->game,req->digest,req->session,req->epoch,&region,1,0,&before)||
    before.entry_count!=1||strcmp(before.entries[0].region,"state-captured")||before.entries[0].kind!=HCIV2_FINAL||!before.entries[0].workspace_present)goto done;
 fd=openat(held[6],"state-captured",O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(fd<0)goto done;
 if(fstat(fd,&first)||fstatat(held[6],"state-captured",&b,AT_SYMLINK_NOFOLLOW)||!S_ISREG(first.st_mode)||first.st_uid!=uid||
    (first.st_mode&0777)!=0600||first.st_nlink!=1||first.st_size<=0||first.st_size>16*1024*1024||first.st_size>(off_t)capacity||!same_staged_file(&first,&b))goto done;
 size=(size_t)first.st_size;bytes=malloc(size);if(!bytes)goto done;
 for(size_t pos=0;pos<size;){ssize_t got=pread(fd,bytes+pos,size-pos,(off_t)pos);if(got<0&&errno==EINTR)continue;if(got<=0){errno=EIO;goto done;}pos+=(size_t)got;}
 for(size_t pos=0;pos<size;){size_t part=size-pos;if(part>sizeof again)part=sizeof again;ssize_t got=pread(fd,again,part,(off_t)pos);if(got<0&&errno==EINTR)continue;if(got<=0||memcmp(again,bytes+pos,(size_t)got)){errno=EIO;goto done;}pos+=(size_t)got;}
 if(fstat(fd,&last)||!same_staged_file(&first,&last)||fstatat(held[6],"state-captured",&b,AT_SYMLINK_NOFOLLOW)||!same_staged_file(&first,&b)||
    hc_recovery_observe(held[6],"state-binding",req->game,req->digest,req->session,req->epoch,&region,1,0,&after)||!same_observation(&before,&after)||
    fstat(fd,&last)||!same_staged_file(&first,&last)||fstatat(held[6],"state-captured",&b,AT_SYMLINK_NOFOLLOW)||!same_staged_file(&first,&b))goto done;
 for(size_t i=0;i<7;i++){int parent=i?held[i-1]:profiles;if(fstat(held[i],&a)||fstatat(parent,names[i],&b,AT_SYMLINK_NOFOLLOW)||!S_ISDIR(b.st_mode)||a.st_dev!=b.st_dev||a.st_ino!=b.st_ino||a.st_mode!=b.st_mode||a.st_uid!=b.st_uid)goto done;}
 if(fstat(profiles,&a)||fstat(named,&b)||a.st_dev!=b.st_dev||a.st_ino!=b.st_ino)goto done;ok=1;
done: {int saved=errno;if(fd>=0&&close(fd))ok=0;for(int i=6;i>=0;i--)if(held[i]>=0&&close(held[i]))ok=0;if(named>=0&&close(named))ok=0;
 if(ok){*out=after;memcpy(output,bytes,size);*length=size;}free(bytes);if(!ok){errno=saved?saved:EIO;return -1;}return 0;}
}
int hc_recovery_collect_game_time_seed(int profiles,const char *root,uid_t uid,const HCLaunchRequest *req,HCRecoveryObservation *out,void *output,size_t capacity,size_t *length){
 unsigned char wire[HC_LAUNCH_REQUEST_SIZE],bytes[21];int held[6]={-1,-1,-1,-1,-1,-1},named=-1,fd=-1,ok=0;struct stat a,b,first,last;HCRecoveryObservation before,after;uint64_t value=0;size_t size=0;
 char token[33],workspace[44],path[1024];static const char hex[]="0123456789abcdef";
 if(!root||root[0]!='/'||strnlen(root,1024)>=1024||!req||uid!=geteuid()||!out||!output||!capacity||!length||hc_launch_request_encode(req,wire)){errno=EINVAL;return -1;}
 if(fstat(profiles,&a)||!S_ISDIR(a.st_mode)||a.st_uid!=uid||(a.st_mode&0022))goto done;
 named=open(root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(named<0||fstat(named,&b)||a.st_dev!=b.st_dev||a.st_ino!=b.st_ino)goto done;
 for(size_t i=0;i<16;i++){token[2*i]=hex[req->session[i]>>4];token[2*i+1]=hex[req->session[i]&15];}token[32]=0;
 if(snprintf(workspace,sizeof workspace,"checkpoint-%s",token)!=(int)(sizeof workspace-1))goto done;
 const char *names[]={req->game,"hakchi",HC_COMPATIBILITY_ENGINE_ID,req->digest,"sessions",workspace};
 for(size_t i=0;i<6;i++){held[i]=open_existing_dir(i?held[i-1]:profiles,names[i],uid,i?1:0);if(held[i]<0)goto done;}
 int n=snprintf(path,sizeof path,"%s/%s/hakchi/%s/%s/sessions/%s/time-original",root,req->game,HC_COMPATIBILITY_ENGINE_ID,req->digest,workspace);
 if(n<=0||(size_t)n>=sizeof path){errno=EINVAL;goto done;}
 HCSessionExpected region={held[5],path,106};
 if(hc_recovery_observe(held[5],"time-seed-binding",req->game,req->digest,req->session,req->epoch,&region,1,0,&before)||
    before.entry_count!=1||strcmp(before.entries[0].region,"time-original")||before.entries[0].kind!=HCIV2_FINAL||!before.entries[0].workspace_present)goto done;
 fd=openat(held[5],"time-original",O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(fd<0)goto done;
 if(fstat(fd,&first)||fstatat(held[5],"time-original",&b,AT_SYMLINK_NOFOLLOW)||!S_ISREG(first.st_mode)||first.st_uid!=uid||
    (first.st_mode&0777)!=0600||first.st_nlink!=1||first.st_size<=0||first.st_size>(off_t)sizeof bytes||first.st_size>(off_t)capacity||!same_staged_file(&first,&b)||hc_playtime_read(fd,&value))goto done;
 size=(size_t)first.st_size;for(size_t pos=0;pos<size;){ssize_t got=pread(fd,bytes+pos,size-pos,(off_t)pos);if(got<0&&errno==EINTR)continue;if(got<=0){errno=EIO;goto done;}pos+=(size_t)got;}
 if(fstat(fd,&last)||!same_staged_file(&first,&last)||fstatat(held[5],"time-original",&b,AT_SYMLINK_NOFOLLOW)||!same_staged_file(&first,&b)||
    hc_recovery_observe(held[5],"time-seed-binding",req->game,req->digest,req->session,req->epoch,&region,1,0,&after)||!same_observation(&before,&after)||
    fstat(fd,&last)||!same_staged_file(&first,&last)||fstatat(held[5],"time-original",&b,AT_SYMLINK_NOFOLLOW)||!same_staged_file(&first,&b))goto done;
 for(size_t i=0;i<6;i++){int parent=i?held[i-1]:profiles;if(fstat(held[i],&a)||fstatat(parent,names[i],&b,AT_SYMLINK_NOFOLLOW)||!S_ISDIR(b.st_mode)||a.st_dev!=b.st_dev||a.st_ino!=b.st_ino||a.st_mode!=b.st_mode||a.st_uid!=b.st_uid)goto done;}
 if(fstat(profiles,&a)||fstat(named,&b)||a.st_dev!=b.st_dev||a.st_ino!=b.st_ino)goto done;ok=1;
done: {int saved=errno;if(fd>=0&&close(fd))ok=0;for(int i=5;i>=0;i--)if(held[i]>=0&&close(held[i]))ok=0;if(named>=0&&close(named))ok=0;
 if(ok){*out=after;memcpy(output,bytes,size);*length=size;}else errno=saved?saved:EIO;return ok?0:-1;}
}
int hc_recovery_read_staged_png(int dir,const char *binding,const char *game,const char *rom,const uint8_t token[16],uint64_t epoch,const HCSessionExpected *regions,size_t count,size_t index,const char *workspace,void *output,size_t capacity,size_t *length){
 HCRecoveryObservation first,second;struct stat parent,ws,named,opened,before,after;int w=-1,fd=-1,ok=0;unsigned char *bytes=NULL;size_t size=0;
 if(!regions||index>=count||(regions[index].type!=100&&regions[index].type!=103)||!workspace||strnlen(workspace,44)!=43||!output||!length||!capacity){errno=EINVAL;return -1;}
 if(hc_recovery_observe(dir,binding,game,rom,token,epoch,regions,count,index,&first))goto done;
 const char *base=strrchr(regions[index].identity,'/');if(!base||!base[1]){errno=EINVAL;goto done;}base++;
 unsigned matches=0;for(size_t i=0;i<first.entry_count;i++)if(!strcmp(first.entries[i].workspace,workspace)){
  if(first.entries[i].kind!=HCIV2_FINAL||!first.entries[i].workspace_present||strcmp(first.entries[i].region,base)){errno=EINVAL;goto done;}matches++;
 }
 if(matches!=1){errno=EINVAL;goto done;}
 int parentfd=regions[index].parent;
 if(fstat(parentfd,&parent)||!S_ISDIR(parent.st_mode)||parent.st_uid!=geteuid()||(parent.st_mode&0777)!=0700)goto done;
 w=openat(parentfd,workspace,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(w<0)goto done;
 if(fstat(w,&ws)||fstatat(parentfd,workspace,&named,AT_SYMLINK_NOFOLLOW)||!S_ISDIR(ws.st_mode)||!S_ISDIR(named.st_mode)||ws.st_uid!=geteuid()||(ws.st_mode&0777)!=0700||ws.st_dev!=named.st_dev||ws.st_ino!=named.st_ino)goto done;
 fd=openat(w,"save.tmp",O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(fd<0)goto done;
 if(fstat(fd,&before)||fstatat(w,"save.tmp",&named,AT_SYMLINK_NOFOLLOW)||!S_ISREG(before.st_mode)||before.st_uid!=geteuid()||(before.st_mode&0777)!=0600||before.st_nlink!=1||before.st_size<57||before.st_size>8*1024*1024||before.st_size>(off_t)capacity||!same_staged_file(&before,&named)){errno=EINVAL;goto done;}
 size=(size_t)before.st_size;bytes=malloc(size);if(!bytes)goto done;
 for(size_t pos=0;pos<size;){ssize_t n=pread(fd,bytes+pos,size-pos,(off_t)pos);if(n<0&&errno==EINTR)continue;if(n<=0){errno=EIO;goto done;}pos+=(size_t)n;}
 if(hc_screenshot_png(bytes,size)||fstat(fd,&after)||!same_staged_file(&before,&after)||fstatat(w,"save.tmp",&named,AT_SYMLINK_NOFOLLOW)||!same_staged_file(&before,&named))goto done;
 if(hc_recovery_observe(dir,binding,game,rom,token,epoch,regions,count,index,&second)||!same_observation(&first,&second))goto done;
 if(fstat(w,&opened)||fstatat(parentfd,workspace,&named,AT_SYMLINK_NOFOLLOW)||!S_ISDIR(named.st_mode)||opened.st_dev!=ws.st_dev||opened.st_ino!=ws.st_ino||opened.st_uid!=ws.st_uid||opened.st_mode!=ws.st_mode||named.st_dev!=ws.st_dev||named.st_ino!=ws.st_ino||fstat(fd,&after)||!same_staged_file(&before,&after)||fstatat(w,"save.tmp",&named,AT_SYMLINK_NOFOLLOW)||!same_staged_file(&before,&named))goto done;
 ok=1;
 done: {int saved=errno;if(fd>=0&&close(fd))ok=0;if(w>=0&&close(w))ok=0;if(ok){memcpy(output,bytes,size);*length=size;}free(bytes);if(!ok){errno=saved?saved:EIO;return -1;}return 0;}
}
/* Publication temporarily links the old target as workspace/previous. Only
 * accept that extra link when the observed journal identifies precisely that
 * workspace and the two names still refer to the same regular file. */
static int current_is_retained_previous(int parent,uid_t uid,const struct stat *current,const HCRecoveryObservation *observation,const char *leaf){
 const HCIV2Entry *entry=NULL;size_t matches=0;
 for(size_t i=0;i<observation->entry_count;i++)if(!strcmp(observation->entries[i].region,leaf)){
  entry=&observation->entries[i];matches++;
 }
 if(matches!=1||!entry->workspace_present||current->st_nlink!=2)return 0;
 struct stat before,held,named,previous;int fd=-1,ok=0;
 if(fstatat(parent,entry->workspace,&before,AT_SYMLINK_NOFOLLOW)||!S_ISDIR(before.st_mode)||before.st_uid!=uid||(before.st_mode&0777)!=0700)goto done;
 fd=openat(parent,entry->workspace,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)goto done;
 if(fstat(fd,&held)||fstatat(parent,entry->workspace,&named,AT_SYMLINK_NOFOLLOW)||
    before.st_dev!=held.st_dev||before.st_ino!=held.st_ino||before.st_mode!=held.st_mode||before.st_uid!=held.st_uid||
    named.st_dev!=held.st_dev||named.st_ino!=held.st_ino||named.st_mode!=held.st_mode||named.st_uid!=held.st_uid||
    fstatat(fd,"previous",&previous,AT_SYMLINK_NOFOLLOW)||!S_ISREG(previous.st_mode)||previous.st_dev!=current->st_dev||previous.st_ino!=current->st_ino||
    previous.st_uid!=current->st_uid||previous.st_mode!=current->st_mode||previous.st_size!=current->st_size||previous.st_nlink!=2)goto done;
 ok=1;
done: if(fd>=0&&close(fd))ok=0;return ok;
}
int hc_recovery_read_current_game(int profiles,const char *root,uid_t uid,const HCLaunchRequest *req,size_t index,HCRecoveryLiveSave *out){
 int held[4]={-1,-1,-1,-1},fd=-1,ok=0;struct stat a,b,named;HCRecoveryObservation first,second;HCRecoveryLiveSave *result=NULL;unsigned char block[4096];
 if(!out||!req||!root||index>=2){errno=EINVAL;return -1;}
 result=calloc(1,sizeof *result);if(!result)return -1;
 if(hc_recovery_observe_game(profiles,root,uid,req,index,&first))goto done;
 result->device=first.device;result->inode=first.inode;
 held[0]=open_existing_dir(profiles,req->game,uid,0);if(held[0]<0)goto done;
 held[1]=open_existing_dir(held[0],"hakchi",uid,1);if(held[1]<0)goto done;
 held[2]=open_existing_dir(held[1],HC_COMPATIBILITY_ENGINE_ID,uid,1);if(held[2]<0)goto done;
 held[3]=open_existing_dir(held[2],req->digest,uid,1);if(held[3]<0)goto done;
 if(fstat(held[3],&a)||(uint64_t)a.st_dev!=first.device||(uint64_t)a.st_ino!=first.inode){errno=EIO;goto done;}
 const char *leaf=index?"battery.rtc":"battery.srm";
 fd=openat(held[3],leaf,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);
 if(fd<0){if(errno!=ENOENT)goto done;}
 else {
  if(fstat(fd,&a)||!S_ISREG(a.st_mode)||a.st_uid!=uid||(a.st_mode&0022)||
     (a.st_nlink!=1&&!current_is_retained_previous(held[3],uid,&a,&first,leaf))||a.st_size<=0||a.st_size>(off_t)sizeof result->bytes){errno=EINVAL;goto done;}
  result->present=1;result->length=(size_t)a.st_size;size_t pos=0;
  while(pos<result->length){ssize_t n=pread(fd,result->bytes+pos,result->length-pos,(off_t)pos);if(n<0&&errno==EINTR)continue;if(n<=0){errno=EIO;goto done;}pos+=(size_t)n;}
  pos=0;while(pos<result->length){size_t chunk=result->length-pos;if(chunk>sizeof block)chunk=sizeof block;ssize_t n=pread(fd,block,chunk,(off_t)pos);if(n<0&&errno==EINTR)continue;if(n<=0||memcmp(block,result->bytes+pos,(size_t)n)){errno=EIO;goto done;}pos+=(size_t)n;}
  if(fstat(fd,&b)||fstatat(held[3],leaf,&named,AT_SYMLINK_NOFOLLOW)||!S_ISREG(named.st_mode)||a.st_dev!=b.st_dev||a.st_ino!=b.st_ino||a.st_size!=b.st_size||a.st_nlink!=b.st_nlink||a.st_uid!=b.st_uid||a.st_mode!=b.st_mode||a.st_dev!=named.st_dev||a.st_ino!=named.st_ino){errno=EIO;goto done;}
 }
 if(hc_recovery_observe_game(profiles,root,uid,req,index,&second)||!same_observation(&first,&second)){errno=EIO;goto done;}
 if(!result->present&&(fstatat(held[3],leaf,&named,AT_SYMLINK_NOFOLLOW)==0||errno!=ENOENT)){errno=EIO;goto done;}
 if(result->present&&(fstat(fd,&b)||fstatat(held[3],leaf,&named,AT_SYMLINK_NOFOLLOW)||!S_ISREG(named.st_mode)||a.st_dev!=b.st_dev||a.st_ino!=b.st_ino||a.st_size!=b.st_size||a.st_nlink!=b.st_nlink||a.st_uid!=b.st_uid||a.st_mode!=b.st_mode||a.st_dev!=named.st_dev||a.st_ino!=named.st_ino||
    (b.st_nlink!=1&&!current_is_retained_previous(held[3],uid,&b,&second,leaf)))){errno=EIO;goto done;}
 const char *names[]={req->game,"hakchi",HC_COMPATIBILITY_ENGINE_ID,req->digest};
 for(size_t i=0;i<4;i++){int parent=i?held[i-1]:profiles;if(fstat(held[i],&a)||fstatat(parent,names[i],&b,AT_SYMLINK_NOFOLLOW)||!S_ISDIR(b.st_mode)||a.st_dev!=b.st_dev||a.st_ino!=b.st_ino||a.st_mode!=b.st_mode||a.st_uid!=b.st_uid){errno=EIO;goto done;}}
 ok=1;
 done: {int saved=errno;if(fd>=0&&close(fd))ok=0;for(int i=3;i>=0;i--)if(held[i]>=0&&close(held[i]))ok=0;if(ok)*out=*result;free(result);if(!ok){errno=saved?saved:EIO;return -1;}return 0;}
}
