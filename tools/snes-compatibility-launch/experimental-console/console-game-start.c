#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#include "console-game.h"
#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* Records are untrusted correlation data. The caller must independently
 * authenticate the request, manager paths and private workspace. */
static int manager_path(const char *path,const char *game){
 char profile[128],cache[128];size_t n=strnlen(path,HC_ARGUMENT_BYTES);
 if(!n||n>=HC_ARGUMENT_BYTES||path[0]!='/')return 0;
 int a=snprintf(profile,sizeof profile,"/var/lib/clover/profiles/0/%s/",game),b=snprintf(cache,sizeof cache,"/var/cache/clover/volatile/%s/",game);
 if(a<=0||b<=0||a>=(int)sizeof profile||b>=(int)sizeof cache)return 0;
 size_t prefix=!strncmp(path,profile,(size_t)a)?(size_t)a:!strncmp(path,cache,(size_t)b)?(size_t)b:0;
 if(!prefix||!path[prefix])return 0;
 size_t begin=prefix;
 for(size_t i=prefix;i<=n;i++){
  unsigned char ch=(unsigned char)path[i];
  if(ch=='/'||ch==0){size_t len=i-begin;if(!len||(len==1&&path[begin]=='.')||(len==2&&path[begin]=='.'&&path[begin+1]=='.'))return 0;begin=i+1;continue;}
  if(!((ch>='a'&&ch<='z')||(ch>='A'&&ch<='Z')||(ch>='0'&&ch<='9')||ch=='_'||ch=='-'||ch=='.'))return 0;
 }
 return 1;
}
static int same_ascii_path(const char *a,const char *b){
 while(*a&&*b){unsigned char x=(unsigned char)*a++,y=(unsigned char)*b++;if(x>='A'&&x<='Z')x+=32;if(y>='A'&&y<='Z')y+=32;if(x!=y)return 0;}
 return *a==*b;
}
static int manager_record_encode(const HCLaunchRequest *request,const HCManagerCheckpointPaths *paths,const HCManagerTimePaths *time,unsigned char *out,size_t *length){
 unsigned char frame[HC_LAUNCH_REQUEST_SIZE];size_t a,b,c,d,e;
 if(!request||!paths||!time||!out||!length||(paths->have_image!=0&&paths->have_image!=1)||(paths->have_save!=0&&paths->have_save!=1)||(paths->have_load!=0&&paths->have_load!=1)||(time->have_load!=0&&time->have_load!=1)||(time->have_save!=0&&time->have_save!=1)||hc_launch_request_encode(request,frame))return -1;
 a=paths->have_save?strnlen(paths->save,HC_ARGUMENT_BYTES):0;b=paths->have_image?strnlen(paths->image,HC_ARGUMENT_BYTES):0;
 c=time->have_load?strnlen(time->load,HC_ARGUMENT_BYTES):0;d=time->have_save?strnlen(time->save,HC_ARGUMENT_BYTES):0;
 e=paths->have_load?strnlen(paths->load,HC_ARGUMENT_BYTES):0;
 if((paths->have_save&&(!a||a>=HC_ARGUMENT_BYTES||!manager_path(paths->save,request->game)))||(!paths->have_save&&paths->save[0])||(paths->have_image&&(!b||b>=HC_ARGUMENT_BYTES||!manager_path(paths->image,request->game)))||(!paths->have_image&&paths->image[0])||(paths->have_save&&paths->have_image&&same_ascii_path(paths->save,paths->image)))return -1;
 if((paths->have_load&&(!e||e>=HC_ARGUMENT_BYTES||!manager_path(paths->load,request->game)))||(!paths->have_load&&paths->load[0])||
    (paths->have_load&&paths->have_image&&same_ascii_path(paths->load,paths->image))||
    (time->have_load&&(!c||c>=HC_ARGUMENT_BYTES||!manager_path(time->load,request->game)))||(!time->have_load&&time->load[0])||
    (time->have_save&&(!d||d>=HC_ARGUMENT_BYTES||!manager_path(time->save,request->game)))||(!time->have_save&&time->save[0]))return -1;
 const char *timed[]={time->have_load?time->load:NULL,time->have_save?time->save:NULL};
 char sram[HC_ARGUMENT_BYTES],rtc[HC_ARGUMENT_BYTES];
 int x=snprintf(sram,sizeof sram,"/var/lib/clover/profiles/0/%s/hakchi/%s/%s/battery.srm",request->game,HC_COMPATIBILITY_ENGINE_ID,request->digest);
 int y=snprintf(rtc,sizeof rtc,"/var/lib/clover/profiles/0/%s/hakchi/%s/%s/battery.rtc",request->game,HC_COMPATIBILITY_ENGINE_ID,request->digest);
 if(x<=0||y<=0||(size_t)x>=sizeof sram||(size_t)y>=sizeof rtc)return -1;
 for(size_t i=0;i<2;i++)if(timed[i]&&((paths->have_save&&same_ascii_path(timed[i],paths->save))||(paths->have_image&&same_ascii_path(timed[i],paths->image))||(paths->have_load&&same_ascii_path(timed[i],paths->load))||same_ascii_path(timed[i],sram)||same_ascii_path(timed[i],rtc)))return -1;
 if(paths->have_load&&(same_ascii_path(paths->load,sram)||same_ascii_path(paths->load,rtc)))return -1;
 int selected=paths->have_load,extended=time->have_load||time->have_save||selected;
 memcpy(out,selected?"HCMGR3\0\0":extended?"HCMGR2\0\0":(paths->have_image||paths->have_save)?"HCSHOT1\0":"HCSESS1\0",8);memcpy(out+8,frame,sizeof frame);size_t p=8+sizeof frame;
 out[p++]=(unsigned char)a;out[p++]=(unsigned char)(a>>8);out[p++]=(unsigned char)b;out[p++]=(unsigned char)(b>>8);
 if(extended){out[p++]=(unsigned char)c;out[p++]=(unsigned char)(c>>8);out[p++]=(unsigned char)d;out[p++]=(unsigned char)(d>>8);}
 if(selected){out[p++]=(unsigned char)e;out[p++]=(unsigned char)(e>>8);}
 memcpy(out+p,paths->save,a);p+=a;memcpy(out+p,paths->image,b);p+=b;
 if(extended){memcpy(out+p,time->load,c);p+=c;memcpy(out+p,time->save,d);p+=d;}
 if(selected){memcpy(out+p,paths->load,e);p+=e;}*length=p;return 0;
}
static int manager_record_check(int directory,const unsigned char *expected,size_t length){
 struct stat dir,file,named,after;unsigned char actual[HC_MANAGER_RECORD_MAX];int fd=-1,ok=0;
 if(fstat(directory,&dir)||!S_ISDIR(dir.st_mode)||dir.st_uid!=geteuid()||(dir.st_mode&0777)!=0700)return -1;
 fd=openat(directory,"manager.meta",O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return -1;
 if(fstat(fd,&file)||!S_ISREG(file.st_mode)||file.st_uid!=geteuid()||(file.st_mode&0777)!=0600||file.st_nlink!=1||file.st_size!=(off_t)length)goto done;
 for(size_t pos=0;pos<length;){ssize_t n=pread(fd,actual+pos,length-pos,(off_t)pos);if(n<0&&errno==EINTR)continue;if(n<=0)goto done;pos+=(size_t)n;}
 if(memcmp(actual,expected,length)||fstat(fd,&after)||fstatat(directory,"manager.meta",&named,AT_SYMLINK_NOFOLLOW)||
    !S_ISREG(named.st_mode)||after.st_dev!=file.st_dev||after.st_ino!=file.st_ino||after.st_size!=file.st_size||after.st_nlink!=file.st_nlink||after.st_uid!=file.st_uid||after.st_mode!=file.st_mode||
    named.st_dev!=file.st_dev||named.st_ino!=file.st_ino||named.st_size!=file.st_size||named.st_nlink!=file.st_nlink||named.st_uid!=file.st_uid||named.st_mode!=file.st_mode)goto done;
#ifdef __APPLE__
 if(after.st_mtimespec.tv_sec!=file.st_mtimespec.tv_sec||after.st_mtimespec.tv_nsec!=file.st_mtimespec.tv_nsec||after.st_ctimespec.tv_sec!=file.st_ctimespec.tv_sec||after.st_ctimespec.tv_nsec!=file.st_ctimespec.tv_nsec)goto done;
#else
 if(after.st_mtim.tv_sec!=file.st_mtim.tv_sec||after.st_mtim.tv_nsec!=file.st_mtim.tv_nsec||after.st_ctim.tv_sec!=file.st_ctim.tv_sec||after.st_ctim.tv_nsec!=file.st_ctim.tv_nsec)goto done;
#endif
 ok=1;
done: {int saved=errno;if(close(fd))ok=0;if(!ok){errno=saved?saved:EIO;return -1;}return 0;}
}
int hc_console_game_check_manager_record_full(int directory,const HCLaunchRequest *request,const HCManagerCheckpointPaths *paths,const HCManagerTimePaths *time){
 unsigned char bytes[HC_MANAGER_RECORD_MAX];size_t n=0;
 if(manager_record_encode(request,paths,time,bytes,&n)){errno=EINVAL;return -1;}
 return manager_record_check(directory,bytes,n);
}
int hc_console_game_check_manager_record(int directory,const HCLaunchRequest *request,const HCManagerCheckpointPaths *paths){HCManagerTimePaths time={0};if(!paths||paths->have_load){errno=EINVAL;return -1;}return hc_console_game_check_manager_record_full(directory,request,paths,&time);}
int hc_console_game_observe_manager_record_full(int directory,const char *game,const char *digest,HCLaunchRequest *out,HCManagerCheckpointPaths *paths_out,HCManagerTimePaths *time_out){
 unsigned char bytes[HC_MANAGER_RECORD_MAX],canonical[sizeof bytes];
 HCLaunchRequest request={0};HCManagerCheckpointPaths paths={0};HCManagerTimePaths time={0};struct stat st;size_t size=0,canonical_size=0;int fd=-1,ok=0;
 if(!game||strnlen(game,12)!=11||!digest||strnlen(digest,65)!=64||!out||!paths_out||!time_out){errno=EINVAL;return -1;}
 fd=openat(directory,"manager.meta",O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return -1;
 if(fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_size<119||st.st_size>(off_t)sizeof bytes)goto done;
 size=(size_t)st.st_size;
 for(size_t pos=0;pos<size;){ssize_t n=pread(fd,bytes+pos,size-pos,(off_t)pos);if(n<0&&errno==EINTR)continue;if(n<=0)goto done;pos+=(size_t)n;}
 int selected=!memcmp(bytes,"HCMGR3\0\0",8);int extended=selected||!memcmp(bytes,"HCMGR2\0\0",8);
 if((!extended&&memcmp(bytes,"HCSHOT1\0",8)&&memcmp(bytes,"HCSESS1\0",8))||hc_launch_request_decode(bytes+8,HC_LAUNCH_REQUEST_SIZE,&request)||strcmp(request.game,game)||strcmp(request.digest,digest))goto done;
 size_t a=(size_t)bytes[115]|((size_t)bytes[116]<<8),b=(size_t)bytes[117]|((size_t)bytes[118]<<8);
 size_t c=0,d=0,e=0,header=119;if(extended){if(size<123)goto done;c=(size_t)bytes[119]|((size_t)bytes[120]<<8);d=(size_t)bytes[121]|((size_t)bytes[122]<<8);header=123;}
 if(selected){if(size<125)goto done;e=(size_t)bytes[123]|((size_t)bytes[124]<<8);header=125;}
 if(a>=HC_ARGUMENT_BYTES||b>=HC_ARGUMENT_BYTES||c>=HC_ARGUMENT_BYTES||d>=HC_ARGUMENT_BYTES||e>=HC_ARGUMENT_BYTES||header+a+b+c+d+e!=size)goto done;
 paths.have_save=a!=0;paths.have_image=b!=0;paths.have_load=e!=0;time.have_load=c!=0;time.have_save=d!=0;
 memcpy(paths.save,bytes+header,a);memcpy(paths.image,bytes+header+a,b);memcpy(time.load,bytes+header+a+b,c);memcpy(time.save,bytes+header+a+b+c,d);memcpy(paths.load,bytes+header+a+b+c+d,e);
 if(manager_record_encode(&request,&paths,&time,canonical,&canonical_size)||canonical_size!=size||memcmp(bytes,canonical,size)||manager_record_check(directory,bytes,size))goto done;
 ok=1;
done: {int saved=errno;if(close(fd))ok=0;if(!ok){errno=saved?saved:EIO;return -1;}*out=request;*paths_out=paths;*time_out=time;return 0;}
}
int hc_console_game_observe_manager_record(int directory,const char *game,const char *digest,HCLaunchRequest *out,HCManagerCheckpointPaths *paths_out){
 HCLaunchRequest request={0};HCManagerCheckpointPaths paths={0};HCManagerTimePaths time={0};
 if(!out||!paths_out||hc_console_game_observe_manager_record_full(directory,game,digest,&request,&paths,&time)||time.have_load||time.have_save||paths.have_load){errno=EINVAL;return -1;}
 *out=request;*paths_out=paths;return 0;
}
int hc_console_game_export_manager_record(int directory,const char *game,const char *digest,void *output,size_t capacity,size_t *length){
 HCLaunchRequest request={0};HCManagerCheckpointPaths paths={0};HCManagerTimePaths time={0};unsigned char bytes[HC_MANAGER_RECORD_MAX];size_t size=0;
 if(!output||!length){errno=EINVAL;return -1;}
 if(hc_console_game_observe_manager_record_full(directory,game,digest,&request,&paths,&time)||manager_record_encode(&request,&paths,&time,bytes,&size))return -1;
 if(size>capacity){errno=ENOSPC;return -1;}
 memcpy(output,bytes,size);*length=size;return 0;
}
static int observation_order(const void *a,const void *b){return strcmp(((const HCManagerRecordObservation *)a)->workspace,((const HCManagerRecordObservation *)b)->workspace);}
int hc_console_game_check_manager_record_inventory(int parent,const char *game,const char *digest){
 struct stat root,before,held,named,after;DIR *directory=NULL;int scan=-1,session=-1,ok=0;size_t seen=0;
 if(!game||strnlen(game,12)!=11||!digest||strnlen(digest,65)!=64||fstat(parent,&root)||!S_ISDIR(root.st_mode)||root.st_uid!=geteuid()||(root.st_mode&0777)!=0700){errno=EINVAL;return -1;}
 scan=openat(parent,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(scan<0)return -1;
 directory=fdopendir(scan);if(!directory){close(scan);return -1;}scan=-1;
 for(;;){errno=0;struct dirent *entry=readdir(directory);if(!entry){if(errno)goto done;break;}
  if(++seen>8192){errno=EOVERFLOW;goto done;}
  if(strncmp(entry->d_name,"checkpoint-",11))continue;
  if(strnlen(entry->d_name,44)!=43){errno=EINVAL;goto done;}
  int nonzero=0;for(size_t i=11;i<43;i++){char c=entry->d_name[i];if(!((c>='0'&&c<='9')||(c>='a'&&c<='f'))){errno=EINVAL;goto done;}if(c!='0')nonzero=1;}if(!nonzero){errno=EINVAL;goto done;}
  if(fstatat(parent,entry->d_name,&before,AT_SYMLINK_NOFOLLOW)||!S_ISDIR(before.st_mode)||before.st_uid!=geteuid()||(before.st_mode&0777)!=0700)goto done;
  session=openat(parent,entry->d_name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(session<0)goto done;
  if(fstat(session,&held)||held.st_dev!=before.st_dev||held.st_ino!=before.st_ino||held.st_mode!=before.st_mode||held.st_uid!=before.st_uid)goto done;
  HCLaunchRequest request={0};HCManagerCheckpointPaths paths={0};HCManagerTimePaths time={0};
  if(hc_console_game_observe_manager_record_full(session,game,digest,&request,&paths,&time)){if(errno==ENOENT)errno=EBUSY;goto done;}
  static const char hex[]="0123456789abcdef";
  for(size_t i=0;i<16;i++)if(entry->d_name[11+2*i]!=hex[request.session[i]>>4]||entry->d_name[12+2*i]!=hex[request.session[i]&15]){errno=EINVAL;goto done;}
  if(fstatat(parent,entry->d_name,&named,AT_SYMLINK_NOFOLLOW)||named.st_dev!=held.st_dev||named.st_ino!=held.st_ino||named.st_mode!=held.st_mode||named.st_uid!=held.st_uid)goto done;
  int closed=close(session);session=-1;if(closed)goto done;
 }
 if(fstat(parent,&after)||root.st_dev!=after.st_dev||root.st_ino!=after.st_ino||root.st_mode!=after.st_mode||root.st_uid!=after.st_uid)goto done;
 ok=1;
done: {int saved=errno;if(session>=0&&close(session))ok=0;if(closedir(directory))ok=0;if(!ok){errno=saved?saved:EIO;return -1;}return 0;}
}
int hc_console_game_open_persistent_sessions(int profiles,const char *root,uid_t uid,const char *game,const char *digest){
 HCLaunchRequest request={0};unsigned char frame[HC_LAUNCH_REQUEST_SIZE];int held[5]={-1,-1,-1,-1,-1},namedroot=-1,ok=0,missing=0;struct stat base,named,before,after;
 if(!root||root[0]!='/'||strnlen(root,1024)>=1024||uid!=geteuid()||!game||strnlen(game,12)!=11||!digest||strnlen(digest,65)!=64){errno=EINVAL;return -1;}
 memcpy(request.game,game,12);memcpy(request.digest,digest,65);request.session[0]=1;request.epoch=1;
 if(hc_launch_request_encode(&request,frame)||fstat(profiles,&base)||!S_ISDIR(base.st_mode)||base.st_uid!=uid||(base.st_mode&0022))return -1;
 namedroot=open(root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(namedroot<0||fstat(namedroot,&named)||base.st_dev!=named.st_dev||base.st_ino!=named.st_ino)goto done;
 const char *names[]={game,"hakchi",HC_COMPATIBILITY_ENGINE_ID,digest,"sessions"};
 for(size_t i=0;i<5;i++){
  int parent=i?held[i-1]:profiles;
  if(fstatat(parent,names[i],&before,AT_SYMLINK_NOFOLLOW)){if(i==4&&errno==ENOENT){missing=1;break;}goto done;}
  if(!S_ISDIR(before.st_mode)||before.st_uid!=uid||(i?(before.st_mode&0777)!=0700:(before.st_mode&0022)!=0))goto done;
  held[i]=openat(parent,names[i],O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(held[i]<0||fstat(held[i],&after)||before.st_dev!=after.st_dev||before.st_ino!=after.st_ino||before.st_uid!=after.st_uid||before.st_mode!=after.st_mode)goto done;
 }
 for(size_t i=0;i<(missing?4u:5u);i++){int parent=i?held[i-1]:profiles;if(fstat(held[i],&before)||fstatat(parent,names[i],&after,AT_SYMLINK_NOFOLLOW)||!S_ISDIR(after.st_mode)||before.st_dev!=after.st_dev||before.st_ino!=after.st_ino||before.st_uid!=after.st_uid||before.st_mode!=after.st_mode)goto done;}
 if(missing&&(!fstatat(held[3],"sessions",&after,AT_SYMLINK_NOFOLLOW)||errno!=ENOENT))goto done;
 if(fstat(profiles,&before)||fstat(namedroot,&after)||base.st_dev!=before.st_dev||base.st_ino!=before.st_ino||base.st_uid!=before.st_uid||base.st_mode!=before.st_mode||base.st_dev!=after.st_dev||base.st_ino!=after.st_ino)goto done;
 ok=1;
done: {int saved=errno;for(int i=3;i>=0;i--)if(held[i]>=0&&close(held[i]))ok=0;if(namedroot>=0&&close(namedroot))ok=0;if(!ok){if(held[4]>=0)close(held[4]);errno=saved?saved:EIO;return -1;}if(missing){errno=ENOENT;return -2;}return held[4];}
}
/* Read-only handoff to a frontend which already owns and authenticates its
 * session. The caller must keep the hierarchy stable and exclude writers. */
int hc_console_game_read_session_manager_full(int profiles,const char *root,uid_t uid,const HCLaunchRequest *request,HCManagerCheckpointPaths *out,HCManagerTimePaths *time_out){
 unsigned char expected[HC_LAUNCH_REQUEST_SIZE],actual[HC_LAUNCH_REQUEST_SIZE];
 HCLaunchRequest found={0};HCManagerCheckpointPaths paths={0};HCManagerTimePaths time={0};struct stat before,held,named,parent_before,parent_after;
 int parent=-1,again=-1,workspace=-1,ok=0;char name[44];static const char hex[]="0123456789abcdef";
 if(!root||!request||!out||!time_out||uid!=geteuid()||hc_launch_request_encode(request,expected)){errno=EINVAL;return -1;}
 memcpy(name,"checkpoint-",11);for(size_t i=0;i<16;i++){name[11+2*i]=hex[request->session[i]>>4];name[12+2*i]=hex[request->session[i]&15];}name[43]=0;
 parent=hc_console_game_open_persistent_sessions(profiles,root,uid,request->game,request->digest);if(parent<0)goto done;
 if(fstat(parent,&parent_before)||fstatat(parent,name,&before,AT_SYMLINK_NOFOLLOW)||!S_ISDIR(before.st_mode)||before.st_uid!=uid||(before.st_mode&0777)!=0700)goto done;
 workspace=openat(parent,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(workspace<0)goto done;
 if(fstat(workspace,&held)||before.st_dev!=held.st_dev||before.st_ino!=held.st_ino||before.st_mode!=held.st_mode||before.st_uid!=held.st_uid||
    hc_console_game_observe_manager_record_full(workspace,request->game,request->digest,&found,&paths,&time)||hc_launch_request_encode(&found,actual)||memcmp(expected,actual,sizeof expected)||
    hc_console_game_check_manager_record_full(workspace,request,&paths,&time)||fstatat(parent,name,&named,AT_SYMLINK_NOFOLLOW)||named.st_dev!=held.st_dev||named.st_ino!=held.st_ino||named.st_mode!=held.st_mode||named.st_uid!=held.st_uid)goto done;
 again=hc_console_game_open_persistent_sessions(profiles,root,uid,request->game,request->digest);if(again<0||fstat(again,&parent_after)||
    parent_before.st_dev!=parent_after.st_dev||parent_before.st_ino!=parent_after.st_ino||parent_before.st_mode!=parent_after.st_mode||parent_before.st_uid!=parent_after.st_uid)goto done;
 ok=1;
done: {int saved=errno;if(workspace>=0&&close(workspace))ok=0;if(again>=0&&close(again))ok=0;if(parent>=0&&close(parent))ok=0;if(!ok){errno=saved?saved:EIO;return -1;}*out=paths;*time_out=time;return 0;}
}
int hc_console_game_read_session_manager(int profiles,const char *root,uid_t uid,const HCLaunchRequest *request,HCManagerCheckpointPaths *out){
 HCManagerCheckpointPaths paths={0};HCManagerTimePaths time={0};
 if(!out||hc_console_game_read_session_manager_full(profiles,root,uid,request,&paths,&time)||time.have_load||time.have_save||paths.have_load){errno=EINVAL;return -1;}
 *out=paths;return 0;
}
int hc_console_game_inventory_manager_records(int parent,const char *game,const char *digest,HCManagerRecordObservation *out,size_t capacity,size_t *count){
 HCManagerRecordObservation *result=NULL;struct stat root,before,after,named;DIR *directory=NULL;size_t used=0,seen=0;int fd=-1,ok=0;
 if(!game||strnlen(game,12)!=11||!digest||strnlen(digest,65)!=64||(!out&&capacity)||!count||capacity>HC_MANAGER_INVENTORY_MAX||fstat(parent,&root)||!S_ISDIR(root.st_mode)||root.st_uid!=geteuid()||(root.st_mode&0777)!=0700){errno=EINVAL;return -1;}
 result=calloc(capacity?capacity:1,sizeof *result);if(!result)return -1;
 fd=openat(parent,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(fd<0){free(result);return -1;}
 directory=fdopendir(fd);if(!directory){close(fd);free(result);return -1;}fd=-1;
 for(;;){errno=0;struct dirent *entry=readdir(directory);if(!entry){if(errno)goto done;break;}
  if(++seen>8192){errno=EOVERFLOW;goto done;}
  if(strncmp(entry->d_name,"checkpoint-",11))continue;
  if(strnlen(entry->d_name,44)!=43){errno=EINVAL;goto done;}
  if(used==capacity){errno=ENOSPC;goto done;}
  int nonzero=0;for(size_t i=11;i<43;i++){char c=entry->d_name[i];if(!((c>='0'&&c<='9')||(c>='a'&&c<='f'))){errno=EINVAL;goto done;}if(c!='0')nonzero=1;}if(!nonzero){errno=EINVAL;goto done;}
  if(fstatat(parent,entry->d_name,&before,AT_SYMLINK_NOFOLLOW)||!S_ISDIR(before.st_mode)||before.st_uid!=geteuid()||(before.st_mode&0777)!=0700)goto done;
  fd=openat(parent,entry->d_name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)goto done;
  if(fstat(fd,&after)||before.st_dev!=after.st_dev||before.st_ino!=after.st_ino||before.st_mode!=after.st_mode||before.st_uid!=after.st_uid)goto done;
  if(fstatat(fd,"manager.meta",&named,AT_SYMLINK_NOFOLLOW)){
   if(errno!=ENOENT)goto done;result[used].status=HC_MANAGER_RECORD_INCOMPLETE;
  }else{
   if(hc_console_game_observe_manager_record_full(fd,game,digest,&result[used].request,&result[used].paths,&result[used].time))goto done;
   static const char hex[]="0123456789abcdef";
   for(size_t i=0;i<16;i++)if(entry->d_name[11+2*i]!=hex[result[used].request.session[i]>>4]||entry->d_name[12+2*i]!=hex[result[used].request.session[i]&15]){errno=EINVAL;goto done;}
   result[used].status=HC_MANAGER_RECORD_PRESENT;
  }
  if(fstatat(parent,entry->d_name,&named,AT_SYMLINK_NOFOLLOW)||named.st_dev!=before.st_dev||named.st_ino!=before.st_ino||named.st_mode!=before.st_mode||named.st_uid!=before.st_uid)goto done;
  memcpy(result[used++].workspace,entry->d_name,44);if(close(fd)){fd=-1;goto done;}fd=-1;
 }
 if(fstat(parent,&after)||root.st_dev!=after.st_dev||root.st_ino!=after.st_ino||root.st_uid!=after.st_uid||root.st_mode!=after.st_mode)goto done;
 if(used>capacity){errno=ENOSPC;goto done;}
 qsort(result,used,sizeof result[0],observation_order);ok=1;
done: {int saved=errno;if(fd>=0&&close(fd))ok=0;if(closedir(directory))ok=0;if(!ok){free(result);errno=saved?saved:EIO;return -1;}if(used)memcpy(out,result,used*sizeof result[0]);free(result);*count=used;return 0;}
}
#ifndef HC_MANAGER_READ_ONLY
static int manager_record_create(int directory,const HCLaunchRequest *request,const HCManagerCheckpointPaths *paths,const HCManagerTimePaths *time){
 unsigned char bytes[HC_MANAGER_RECORD_MAX];size_t n=0;struct stat dir;int fd=-1,result=-1;
 if(manager_record_encode(request,paths,time,bytes,&n)||fstat(directory,&dir)||!S_ISDIR(dir.st_mode)||dir.st_uid!=geteuid()||(dir.st_mode&0777)!=0700){errno=EINVAL;return -1;}
 fd=openat(directory,"manager.meta",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0)return -1;
 for(size_t pos=0;pos<n;){ssize_t wrote=write(fd,bytes+pos,n-pos);if(wrote<0&&errno==EINTR)continue;if(wrote<=0)goto done;pos+=(size_t)wrote;}
 if(fsync(fd))goto done;result=0;
done: {int saved=errno;if(close(fd))result=-1;if(!result&&(fsync(directory)||manager_record_check(directory,bytes,n)))result=-1;if(result)errno=saved?saved:EIO;return result;}
}
int hc_console_game_prepare_manager_record(HCConsoleGame *game,HCConsoleRuntime *runtime,int argc,const char *const argv[]){
 HCCompatibilityMenuCommand parsed;
 if(!game||!game->rom.ready||!runtime||runtime->attempted||runtime->workspace<0||hc_parse_compatibility_menu_command(argc,argv,&parsed)||
    strcmp(parsed.game,game->command.game)||strcmp(parsed.rom_name,game->command.rom_name)||
    strcmp(runtime->request.game,parsed.game)||strcmp(runtime->request.digest,parsed.digest)||
    parsed.manager.present!=game->command.manager.present||parsed.manager.wait_fd!=game->command.manager.wait_fd||
    parsed.manager.start_fd!=game->command.manager.start_fd||parsed.manager.finish_fd!=game->command.manager.finish_fd||
    hc_verified_launch_recheck(&game->rom)){errno=EINVAL;return -1;}
 for(unsigned i=0;i<HC_OPTION_COUNT;i++)if((parsed.manager.present&(1u<<i))&&strcmp(parsed.manager.values[i],game->command.manager.values[i])){errno=EINVAL;return -1;}
 /* A stock session records its identity before preparing its save journal.
  * A later entry handoff may reuse only that exact, unchanged record. */
 if(runtime->claimed)return hc_console_game_check_manager_record_full(runtime->workspace,&runtime->request,&parsed.checkpoint,&parsed.time);
 runtime->claimed=1;
 if(manager_record_create(runtime->workspace,&runtime->request,&parsed.checkpoint,&parsed.time))return -1;
 return 0;
}
int hc_console_game_start(HCConsoleGame *game,HCConsoleRuntime *runtime,HCConsoleSupervisor *supervisor,int argc,const char *const argv[],const HCConsoleStartSpec *trusted,unsigned timeout,const char *core){
 if(!trusted||hc_console_game_prepare_manager_record(game,runtime,argc,argv))return -1;
 HCConsoleStartSpec spec=*trusted;spec.verified_rom=&game->rom;
 return hc_console_runtime_start_command(runtime,supervisor,argc,argv,&spec,timeout,core);
}
#endif
