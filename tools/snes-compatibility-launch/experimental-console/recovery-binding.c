#define _DARWIN_C_SOURCE 1
#if (defined(HC_RESTORE_TEST_HOOK) || defined(HC_FINISH_TEST_HOOK) || defined(HC_UNPUBLISHED_TEST_HOOK) || defined(HC_UNPUBLISHED_ERROR_TEST_HOOK)) && defined(__arm__)
#error "Crash-injection hooks must not be built for the console."
#endif
#define _GNU_SOURCE 1
#include "recovery-binding.h"
#include "owned_directory.h"
#include <stdlib.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#define LIMIT 20000
static int private_dir(int fd){struct stat s;return fstat(fd,&s)||!S_ISDIR(s.st_mode)||s.st_uid!=geteuid()||(s.st_mode&0777)!=0700?-1:0;}
static int starts_ascii_fold(const char *s,const char *prefix){for(;*prefix;s++,prefix++){unsigned char c=(unsigned char)*s;if(!c)return 0;if(c>='A'&&c<='Z')c=(unsigned char)(c+32);if(c!=(unsigned char)*prefix)return 0;}return 1;}
static int leaf(const char *s){if(!s||!*s||strnlen(s,81)>80||starts_ascii_fold(s,"intent")||starts_ascii_fold(s,"checkpoint-"))return 0;for(;*s;s++)if(!((*s>='a'&&*s<='z')||(*s>='A'&&*s<='Z')||(*s>='0'&&*s<='9')||*s=='-'||*s=='_'))return 0;return 1;}
static int hexstr(const char *s,size_t n){if(!s||strnlen(s,n+1)!=n)return 0;for(size_t i=0;i<n;i++)if(!((s[i]>='0'&&s[i]<='9')||(s[i]>='a'&&s[i]<='f')))return 0;return 1;}
static int region_matches_parent(int parent,const char *identity){
 char path[1024];const char *end=strrchr(identity,'/');if(!end||!end[1])return -1;
 size_t k=(size_t)(end-identity);if(!k)k=1;if(k>=sizeof path)return -1;
 const char *name=end+1;size_t length=strlen(name);if(!length||length>=64||!strcmp(name,".")||!strcmp(name,".."))return -1;
 for(size_t i=0;i<length;i++){unsigned char c=(unsigned char)name[i];if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='-'||c=='_'||c=='.'))return -1;}
 memcpy(path,identity,k);path[k]=0;int fd=open(path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return -1;
 struct stat a,b;int bad=fstat(parent,&a)||fstat(fd,&b)||a.st_dev!=b.st_dev||a.st_ino!=b.st_ino;if(close(fd))bad=1;return bad?-1:0;
}
static int record(char out[LIMIT],size_t *len,const char *game,const char *rom,const uint8_t token[16],uint64_t epoch,const HCSessionExpected *r,size_t n){
 if(!game||strnlen(game,12)!=11||strncmp(game,"CLV-U-",6)||!hexstr(rom,64)||!token||!epoch||!r||!n||n>16||hc_session_validate_regions(r,n))return -1;
 for(size_t i=6;i<11;i++)if(!((game[i]>='A'&&game[i]<='Z')||(game[i]>='0'&&game[i]<='9')))return -1;
 int any=0;char hex[33];for(size_t i=0;i<16;i++){any|=token[i];snprintf(hex+2*i,3,"%02x",token[i]);}if(!any)return -1;
 int z=snprintf(out,LIMIT,"HC-BINDING-1\n%s\n%s\n%s\n%" PRIu64 "\n%zu\n",game,rom,hex,epoch,n);if(z<0||(size_t)z>=LIMIT)return -1;size_t used=(size_t)z;
 for(size_t i=0;i<n;i++){
  struct stat s;if(private_dir(r[i].parent)||fstat(r[i].parent,&s)||!r[i].identity||r[i].identity[0]!='/'||strnlen(r[i].identity,1024)>=1024||strchr(r[i].identity,'\n')||strchr(r[i].identity,'\r')||region_matches_parent(r[i].parent,r[i].identity))return -1;
  for(size_t j=0;j<i;j++)if(!strcmp(r[i].identity,r[j].identity))return -1;
  z=snprintf(out+used,LIMIT-used,"%u %" PRIuMAX " %" PRIuMAX " %s\n",r[i].type,(uintmax_t)s.st_dev,(uintmax_t)s.st_ino,r[i].identity);if(z<0||(size_t)z>=LIMIT-used)return -1;used+=(size_t)z;
 }*len=used;return 0;
}
static int write_all(int fd,const char *p,size_t n){while(n){ssize_t w=write(fd,p,n);if(w<0&&errno==EINTR)continue;if(w<=0)return -1;p+=w;n-=(size_t)w;}return 0;}
static int name_equal(const char *a,const char *b){for(;;a++,b++){unsigned char x=(unsigned char)*a,y=(unsigned char)*b;if(x>='A'&&x<='Z')x=(unsigned char)(x+32);if(y>='A'&&y<='Z')y=(unsigned char)(y+32);if(x!=y)return 0;if(!x)return 1;}}
static int collision(int dir,const char *name,const HCSessionExpected *r,size_t n){struct stat root,s;if(fstat(dir,&root))return -1;for(size_t i=0;i<n;i++){const char *base=strrchr(r[i].identity,'/');if(!base||fstat(r[i].parent,&s))return -1;if(root.st_dev==s.st_dev&&root.st_ino==s.st_ino&&name_equal(name,base+1))return -1;}return 0;}
int hc_binding_create(int dir,const char *name,const char *game,const char *rom,const uint8_t token[16],uint64_t epoch,const HCSessionExpected *r,size_t n){char buf[LIMIT];size_t len;if(private_dir(dir)||!leaf(name)||record(buf,&len,game,rom,token,epoch,r,n)||collision(dir,name,r,n)){errno=EINVAL;return -1;}int fd=openat(dir,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0)return -1;int bad=fchmod(fd,0600)||write_all(fd,buf,len)||fsync(fd);if(close(fd))bad=1;if(bad||fsync(dir))return -1;return 0;}
int hc_binding_inventory(int dir,const char *name,const char *game,const char *rom,const uint8_t token[16],uint64_t epoch,const HCSessionExpected *r,size_t n,size_t index,HCIV2Entry *entries,size_t cap,size_t *count){
 char expected[LIMIT],actual[LIMIT];size_t len;if(private_dir(dir)||!leaf(name)||record(expected,&len,game,rom,token,epoch,r,n)||collision(dir,name,r,n)||index>=n||!count||(!entries&&cap)){errno=EINVAL;return -1;}
 int fd=openat(dir,name,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return -1;struct stat a={0},b={0};int bad=fstat(fd,&a)||!S_ISREG(a.st_mode)||a.st_uid!=geteuid()||(a.st_mode&0777)!=0600||a.st_nlink!=1||a.st_size!=(off_t)len;size_t got=0;
 while(!bad&&got<len){ssize_t x=read(fd,actual+got,len-got);if(x<0&&errno==EINTR)continue;if(x<=0){bad=1;break;}got+=(size_t)x;}
 if(fstat(fd,&b)||a.st_dev!=b.st_dev||a.st_ino!=b.st_ino||a.st_size!=b.st_size)bad=1;if(close(fd))bad=1;
 if(bad||memcmp(actual,expected,len)){errno=EINVAL;return -1;}return hc_session_recovery_inventory(r,n,index,token,entries,cap,count);
}

int hc_binding_retire_orphan(int dir,const char *binding,const char *game,const char *rom,const uint8_t token[16],uint64_t epoch,const HCSessionExpected *regions,size_t count,size_t index,const char *workspace,const void *expected,size_t length){
 if(!workspace||strnlen(workspace,44)!=43||!expected||!length||length>128u*1024u*1024u||!regions||index>=count){errno=EINVAL;return -1;}
 HCIV2Entry *entries=calloc(4096,sizeof(*entries));if(!entries)return -1;
 size_t n=0;int matched=0,result=-1;HCIV2Kind kind=0;
 if(hc_binding_inventory(dir,binding,game,rom,token,epoch,regions,count,index,entries,4096,&n))goto done;
 const char *name=strrchr(regions[index].identity,'/');if(!name||!name[1]){errno=EINVAL;goto done;}name++;
 for(size_t i=0;i<n;i++)if(!strcmp(entries[i].workspace,workspace)){
  if(entries[i].workspace_present||
     (entries[i].kind!=HCIV2_PERIODIC&&entries[i].kind!=HCIV2_FINAL)||strcmp(entries[i].region,name)){errno=EPROTO;goto done;}
  kind=entries[i].kind;matched++;
 }
 if(matched!=1){errno=ENOENT;goto done;}
 int parent=regions[index].parent;struct stat path,held,after;
 if(fstatat(parent,name,&path,AT_SYMLINK_NOFOLLOW)||!S_ISREG(path.st_mode)){errno=EINVAL;goto done;}
 int fd=openat(parent,name,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(fd<0)goto done;
 int bad=fstat(fd,&held)||held.st_dev!=path.st_dev||held.st_ino!=path.st_ino||hc_verify_checkpoint_file(fd,geteuid(),expected,length)||
     fstatat(parent,name,&after,AT_SYMLINK_NOFOLLOW)||held.st_dev!=after.st_dev||held.st_ino!=after.st_ino;
 int saved=errno;if(close(fd)&&!bad){bad=1;saved=errno;}
 if(bad){errno=saved?saved:EIO;goto done;}
 char session[33];static const char hex[]="0123456789abcdef";
 for(size_t i=0;i<16;i++){session[2*i]=hex[token[i]>>4];session[2*i+1]=hex[token[i]&15];}session[32]=0;
 result=hciv2_remove_confirmed_orphan(parent,session,workspace,name,kind);
done:
 free(entries);return result;
}

/* Compare a held file against independently supplied bytes without changing
 * it. A two-link file is permitted only for the explicitly checked hardlink
 * relationships in the caller. */
static int restore_verify(int fd,uid_t uid,const void *expected,size_t length,nlink_t links,struct stat *snapshot){
 struct stat a,b;unsigned char block[4096];size_t pos=0;
 if(!expected||!length||length>128u*1024u*1024u||fstat(fd,&a)||!S_ISREG(a.st_mode)||a.st_uid!=uid||
    (a.st_mode&0022)||a.st_nlink!=links||a.st_size!=(off_t)length){errno=EINVAL;return -1;}
 while(pos<length){size_t n=length-pos;if(n>sizeof block)n=sizeof block;ssize_t r=pread(fd,block,n,(off_t)pos);
  if(r<0&&errno==EINTR)continue;if(r<=0||memcmp(block,(const unsigned char *)expected+pos,(size_t)r)){errno=EIO;return -1;}pos+=(size_t)r;
 }
 if(fstat(fd,&b)||a.st_dev!=b.st_dev||a.st_ino!=b.st_ino||a.st_size!=b.st_size||a.st_nlink!=b.st_nlink||fsync(fd)){errno=EIO;return -1;}
 if(snapshot)*snapshot=b;return 0;
}
static int restore_same(const struct stat *a,const struct stat *b){return a->st_dev==b->st_dev&&a->st_ino==b->st_ino;}
/* Verifies the original target is still exactly the independently expected
 * file or still absent. Exclusive caller control remains required. */
static int unpublished_target(int parent,const char *base,const void *expected,size_t length){
 struct stat held,named;int fd;
 if(!expected&&!length){if(fstatat(parent,base,&named,AT_SYMLINK_NOFOLLOW)==0){errno=EEXIST;return -1;}return errno==ENOENT?0:-1;}
 if(!expected||!length){errno=EINVAL;return -1;}
 fd=openat(parent,base,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return -1;
 int bad=restore_verify(fd,geteuid(),expected,length,1,&held)||fstatat(parent,base,&named,AT_SYMLINK_NOFOLLOW)||!restore_same(&held,&named);
 if(close(fd))bad=1;if(bad){errno=EIO;return -1;}return 0;
}
#include <dirent.h>
int hc_binding_finish_unpublished(int dir,const char *binding,const char *game,const char *rom,const uint8_t token[16],uint64_t epoch,const HCSessionExpected *regions,size_t count,size_t index,const char *workspace,const void *expected,size_t length){
 HCIV2Entry *entries=NULL;size_t n=0;int w=-1,tmp=-1,result=-1,changed=0;struct stat ws,named,held;
 if(!workspace||strnlen(workspace,44)!=43||!regions||index>=count||((expected==NULL)!=(length==0))||length>128u*1024u*1024u){errno=EINVAL;return -1;}
 entries=calloc(4096,sizeof *entries);if(!entries)return -1;
 if(hc_binding_inventory(dir,binding,game,rom,token,epoch,regions,count,index,entries,4096,&n))goto done;
 const char *base=strrchr(regions[index].identity,'/');if(!base||!base[1]){errno=EINVAL;goto done;}base++;
 int found=0,present=0,region_entries=0;for(size_t i=0;i<n;i++){
  if(!strcmp(entries[i].region,base))region_entries++;
  if(!strcmp(entries[i].workspace,workspace)){
   if(entries[i].kind!=HCIV2_FINAL||strcmp(entries[i].region,base)){errno=EPROTO;goto done;}found++;present=entries[i].workspace_present;
  }
 }
 /* The binding inventory already rejects unrecognized regions. Other known
  * regions may have their own pending checkpoints; a second intent for this
  * exact region remains ambiguous and must not be retired here. */
 if(found!=1||region_entries!=1){errno=EPROTO;goto done;}
 int parent=regions[index].parent;if(unpublished_target(parent,base,expected,length))goto done;
 if(present){
  w=openat(parent,workspace,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(w<0)goto done;
  if(fstat(w,&ws)||fstatat(parent,workspace,&named,AT_SYMLINK_NOFOLLOW)||!S_ISDIR(ws.st_mode)||ws.st_uid!=geteuid()||(ws.st_mode&0777)!=0700||!restore_same(&ws,&named)){errno=EIO;goto done;}
  int scanfd=fcntl(w,F_DUPFD_CLOEXEC,3);if(scanfd<0)goto done;DIR *scan=fdopendir(scanfd);if(!scan){close(scanfd);goto done;}
  int bad=0,has_tmp=0;struct dirent *item;
  for(;;){errno=0;item=readdir(scan);if(!item){if(errno)bad=1;break;}if(!strcmp(item->d_name,".")||!strcmp(item->d_name,".."))continue;if(!strcmp(item->d_name,"save.tmp")&&!has_tmp){has_tmp=1;continue;}bad=1;break;}
  if(closedir(scan))bad=1;if(bad){errno=EPROTO;goto done;}
  if(has_tmp){
   tmp=openat(w,"save.tmp",O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(tmp<0)goto done;
   if(fstat(tmp,&held)||!S_ISREG(held.st_mode)||held.st_uid!=geteuid()||(held.st_mode&0777)!=0600||held.st_nlink!=1||held.st_size!=0||fstatat(w,"save.tmp",&named,AT_SYMLINK_NOFOLLOW)||!restore_same(&held,&named)||unpublished_target(parent,base,expected,length)){errno=EIO;goto done;}
   if(unlinkat(w,"save.tmp",0))goto done;changed=1;
#ifdef HC_UNPUBLISHED_TEST_HOOK
   {extern void hc_test_unpublished_hook(int);hc_test_unpublished_hook(1);}
#endif
#ifdef HC_UNPUBLISHED_ERROR_TEST_HOOK
   {extern int hc_test_unpublished_error_hook(int);if(hc_test_unpublished_error_hook(1)){errno=EIO;goto done;}}
#endif
   if(fsync(w))goto done;
  }
  if(fsync(w)||unpublished_target(parent,base,expected,length)||fstatat(parent,workspace,&named,AT_SYMLINK_NOFOLLOW)||!restore_same(&ws,&named))goto done;
  if(unlinkat(parent,workspace,AT_REMOVEDIR))goto done;changed=1;
#ifdef HC_UNPUBLISHED_TEST_HOOK
  {extern void hc_test_unpublished_hook(int);hc_test_unpublished_hook(2);}
#endif
#ifdef HC_UNPUBLISHED_ERROR_TEST_HOOK
  {extern int hc_test_unpublished_error_hook(int);if(hc_test_unpublished_error_hook(2)){errno=EIO;goto done;}}
#endif
  if(fsync(parent))goto done;
 }
 if(unpublished_target(parent,base,expected,length))goto done;
 char session[33];static const char hex[]="0123456789abcdef";for(size_t i=0;i<16;i++){session[i*2]=hex[token[i]>>4];session[i*2+1]=hex[token[i]&15];}session[32]=0;
 result=hciv2_remove_confirmed_orphan(parent,session,workspace,base,HCIV2_FINAL);
done:
 {int saved=errno;if(tmp>=0&&close(tmp)&&result==0){result=-1;saved=EIO;}if(w>=0&&close(w)&&result==0){result=-1;saved=EIO;}free(entries);if(result<0&&changed)result=-2;if(result)errno=saved;return result;}
}
int hc_binding_restore_previous(int dir,const char *binding,const char *game,const char *rom,const uint8_t token[16],uint64_t epoch,const HCSessionExpected *regions,size_t count,size_t index,const char *workspace,const void *expected,size_t length){
 HCIV2Entry *entries=NULL;size_t n=0;int matched=0,w=-1,oldfd=-1,result=-1,changed=0;struct stat ws,named,old,current,retained,again;
 if(!workspace||strnlen(workspace,44)!=43||!expected||!length||length>128u*1024u*1024u||!regions||index>=count){errno=EINVAL;return -1;}
 entries=calloc(4096,sizeof *entries);if(!entries)return -1;
 if(hc_binding_inventory(dir,binding,game,rom,token,epoch,regions,count,index,entries,4096,&n))goto done;
 const char *base=strrchr(regions[index].identity,'/');if(!base||!base[1]){errno=EINVAL;goto done;}base++;
 for(size_t i=0;i<n;i++)if(!strcmp(entries[i].workspace,workspace)){
  if(!entries[i].workspace_present||strcmp(entries[i].region,base)||(entries[i].kind!=HCIV2_PERIODIC&&entries[i].kind!=HCIV2_FINAL)){errno=EPROTO;goto done;}matched++;
 }
 if(matched!=1){errno=ENOENT;goto done;}
 int parent=regions[index].parent;
 w=openat(parent,workspace,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(w<0)goto done;
 if(fstat(w,&ws)||fstatat(parent,workspace,&named,AT_SYMLINK_NOFOLLOW)||!S_ISDIR(ws.st_mode)||!S_ISDIR(named.st_mode)||
    ws.st_uid!=geteuid()||(ws.st_mode&0777)!=0700||!restore_same(&ws,&named)){errno=EIO;goto done;}
 oldfd=openat(w,"previous",O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);
 if(oldfd<0){
  if(errno!=ENOENT)goto done;
  int active=openat(parent,base,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(active<0)goto done;
  int bad=restore_verify(active,geteuid(),expected,length,1,&current)||fstatat(parent,base,&again,AT_SYMLINK_NOFOLLOW)||!restore_same(&current,&again);
  int close_error=close(active);if(bad||close_error){errno=EIO;goto done;}
  if(fsync(parent)||fsync(w)){errno=EIO;goto done;}result=0;goto done;
 }
 if(fstat(oldfd,&old)||fstatat(w,"previous",&named,AT_SYMLINK_NOFOLLOW)||!restore_same(&old,&named)){errno=EIO;goto done;}
 int exists=fstatat(parent,base,&current,AT_SYMLINK_NOFOLLOW)==0;
 if(!exists&&errno!=ENOENT)goto done;
 if(exists&&(!S_ISREG(current.st_mode)||current.st_uid!=geteuid()||(current.st_mode&0022))){errno=EACCES;goto done;}
 if(exists&&restore_same(&old,&current)){
  if(restore_verify(oldfd,geteuid(),expected,length,2,NULL)||fsync(parent)||fsync(w)){errno=EIO;goto done;}result=0;goto done;
 }
 if(restore_verify(oldfd,geteuid(),expected,length,1,&old))goto done;
 if(exists){
  int currentfd=openat(parent,base,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(currentfd<0)goto done;
  int bad=fstat(currentfd,&again)||!restore_same(&current,&again)||!S_ISREG(again.st_mode)||
      again.st_uid!=geteuid()||(again.st_mode&0022)||fsync(currentfd);
  int closed=close(currentfd);if(bad||closed){errno=EIO;goto done;}
  if(fstatat(w,"superseded",&retained,AT_SYMLINK_NOFOLLOW)==0){
   if(!S_ISREG(retained.st_mode)||!restore_same(&retained,&current)||current.st_nlink!=2){errno=EEXIST;goto done;}
  }else{
   if(errno!=ENOENT||current.st_nlink!=1||linkat(parent,base,w,"superseded",0))goto done;
   changed=1;
#ifdef HC_RESTORE_ERROR_TEST_HOOK
   {extern int hc_test_restore_error_hook(int);if(hc_test_restore_error_hook(1)){errno=EIO;goto done;}}
#endif
  }
  if(fstatat(w,"superseded",&retained,AT_SYMLINK_NOFOLLOW)||fstatat(parent,base,&again,AT_SYMLINK_NOFOLLOW)||
     !restore_same(&retained,&current)||!restore_same(&again,&current)||fsync(w)){errno=EIO;goto done;}
 }else if(fstatat(w,"superseded",&retained,AT_SYMLINK_NOFOLLOW)==0||errno!=ENOENT){errno=EEXIST;goto done;}
#ifdef HC_RESTORE_TEST_HOOK
 {extern void hc_test_restore_hook(int);hc_test_restore_hook(1);}
#endif
 if(fstatat(w,"previous",&named,AT_SYMLINK_NOFOLLOW)||!restore_same(&old,&named)){errno=EIO;goto done;}
 if(renameat(w,"previous",parent,base))goto done;changed=1;
#ifdef HC_RESTORE_TEST_HOOK
 {extern void hc_test_restore_hook(int);hc_test_restore_hook(2);}
#endif
 if(fsync(parent)||fsync(w)||fstatat(parent,base,&again,AT_SYMLINK_NOFOLLOW)||!restore_same(&old,&again)||restore_verify(oldfd,geteuid(),expected,length,1,NULL)){errno=EIO;goto done;}
 result=0;
done:
 {int saved=errno;if(oldfd>=0&&close(oldfd)&&result==0){result=-1;saved=EIO;}if(w>=0&&close(w)&&result==0){result=-1;saved=EIO;}free(entries);if(result<0&&changed)result=-2;errno=saved;return result;}
}

/* Complete a final-save journal only after current and previous bytes match
 * caller-retained snapshots. All filesystem mutation is confined to the
 * authenticated workspace and is recoverable via its retained intent. */
#include <dirent.h>
int hc_binding_finish_published(int dir,const char *binding,const char *game,const char *rom,const uint8_t token[16],uint64_t epoch,const HCSessionExpected *regions,size_t count,size_t index,const char *workspace,const void *current,size_t current_len,const void *previous,size_t previous_len){
 HCIV2Entry *entries=NULL;size_t n=0;int w=-1,cur=-1,old=-1,changed=0,result=-1;struct stat ws,named,held,entry;
 if(!workspace||strnlen(workspace,44)!=43||!regions||index>=count||!current||!current_len||((previous==NULL)!=(previous_len==0))){errno=EINVAL;return -1;}
 entries=calloc(4096,sizeof *entries);if(!entries)return -1;
 if(hc_binding_inventory(dir,binding,game,rom,token,epoch,regions,count,index,entries,4096,&n))goto done;
 const char *base=strrchr(regions[index].identity,'/');if(!base||!base[1]){errno=EINVAL;goto done;}base++;
 int found=0,present=0;for(size_t i=0;i<n;i++)if(!strcmp(entries[i].workspace,workspace)){
  if(entries[i].kind!=HCIV2_FINAL||strcmp(entries[i].region,base)){errno=EPROTO;goto done;}found++;present=entries[i].workspace_present;
 }
 if(found!=1){errno=ENOENT;goto done;}
 if(!present){result=hc_binding_retire_orphan(dir,binding,game,rom,token,epoch,regions,count,index,workspace,current,current_len);goto done;}
 int parent=regions[index].parent;
 cur=openat(parent,base,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(cur<0)goto done;
 if(restore_verify(cur,geteuid(),current,current_len,1,&held)||fstatat(parent,base,&named,AT_SYMLINK_NOFOLLOW)||!restore_same(&held,&named)){errno=EIO;goto done;}
 w=openat(parent,workspace,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(w<0)goto done;
 if(fstat(w,&ws)||fstatat(parent,workspace,&named,AT_SYMLINK_NOFOLLOW)||!S_ISDIR(ws.st_mode)||ws.st_uid!=geteuid()||(ws.st_mode&0777)!=0700||!restore_same(&ws,&named)){errno=EIO;goto done;}
 int dupfd=fcntl(w,F_DUPFD_CLOEXEC,3);if(dupfd<0)goto done;DIR *scan=fdopendir(dupfd);if(!scan){close(dupfd);goto done;}
 int bad=0,has_previous=0;struct dirent *item;
 for(;;){errno=0;item=readdir(scan);if(!item){if(errno)bad=1;break;}if(!strcmp(item->d_name,".")||!strcmp(item->d_name,".."))continue;if(!strcmp(item->d_name,"previous")&&!has_previous){has_previous=1;continue;}bad=1;break;}
 if(closedir(scan))bad=1;if(bad){errno=EPROTO;goto done;}
 if(has_previous){
  if(!previous){errno=EEXIST;goto done;}
  old=openat(w,"previous",O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(old<0)goto done;
  if(restore_verify(old,geteuid(),previous,previous_len,1,&entry)||fstatat(w,"previous",&named,AT_SYMLINK_NOFOLLOW)||!restore_same(&entry,&named)){errno=EIO;goto done;}
  if(fstatat(parent,base,&named,AT_SYMLINK_NOFOLLOW)||!restore_same(&held,&named)){errno=EIO;goto done;}
  if(unlinkat(w,"previous",0))goto done;changed=1;
#ifdef HC_FINISH_TEST_HOOK
  {extern void hc_test_finish_hook(int);hc_test_finish_hook(1);}
#endif
  if(fsync(w))goto done;
 }
 if(fstatat(parent,workspace,&named,AT_SYMLINK_NOFOLLOW)||!restore_same(&ws,&named)){errno=EIO;goto done;}
 if(unlinkat(parent,workspace,AT_REMOVEDIR))goto done;changed=1;
#ifdef HC_FINISH_TEST_HOOK
 {extern void hc_test_finish_hook(int);hc_test_finish_hook(2);}
#endif
 if(fsync(parent))goto done;
 result=hc_binding_retire_orphan(dir,binding,game,rom,token,epoch,regions,count,index,workspace,current,current_len);
done:
 {int saved=errno;if(old>=0&&close(old)&&result==0){result=-1;saved=EIO;}if(cur>=0&&close(cur)&&result==0){result=-1;saved=EIO;}if(w>=0&&close(w)&&result==0){result=-1;saved=EIO;}free(entries);if(result<0&&changed)result=-2;errno=saved;return result;}
}

/* Caller must independently prove that the original region was absent and
 * authenticate the exact current bytes, stop all writers and exclude mutation. */
int hc_binding_restore_absent(int dir,const char *binding,const char *game,const char *rom,const uint8_t token[16],uint64_t epoch,const HCSessionExpected *regions,size_t count,size_t index,const char *workspace,const void *expected,size_t length){
 HCIV2Entry *entries=NULL;size_t n=0;int w=-1,current=-1,savedfd=-1,matched=0,changed=0,result=-1;struct stat ws,named,live,retained,after;
 if(!workspace||strnlen(workspace,44)!=43||!expected||!length||length>128u*1024u*1024u||!regions||index>=count){errno=EINVAL;return -1;}
 entries=calloc(4096,sizeof *entries);if(!entries)return -1;
 if(hc_binding_inventory(dir,binding,game,rom,token,epoch,regions,count,index,entries,4096,&n))goto done;
 const char *base=strrchr(regions[index].identity,'/');if(!base||!base[1]){errno=EINVAL;goto done;}base++;
 for(size_t i=0;i<n;i++)if(!strcmp(entries[i].workspace,workspace)){
  if(!entries[i].workspace_present||strcmp(entries[i].region,base)||(entries[i].kind!=HCIV2_FINAL&&entries[i].kind!=HCIV2_PERIODIC)){errno=EPROTO;goto done;}matched++;
 }
 if(matched!=1){errno=ENOENT;goto done;}
 int parent=regions[index].parent;w=openat(parent,workspace,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(w<0)goto done;
 if(fstat(w,&ws)||fstatat(parent,workspace,&named,AT_SYMLINK_NOFOLLOW)||!S_ISDIR(ws.st_mode)||!S_ISDIR(named.st_mode)||ws.st_uid!=geteuid()||(ws.st_mode&0777)!=0700||!restore_same(&ws,&named)){errno=EIO;goto done;}
 if(fstatat(w,"previous",&named,AT_SYMLINK_NOFOLLOW)==0||errno!=ENOENT){errno=EEXIST;goto done;}
 current=openat(parent,base,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);
 if(current<0&&errno!=ENOENT)goto done;
 savedfd=openat(w,"superseded",O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);
 if(savedfd<0&&errno!=ENOENT)goto done;
 if(current<0){
  if(savedfd<0||restore_verify(savedfd,geteuid(),expected,length,1,&retained)||fstatat(w,"superseded",&named,AT_SYMLINK_NOFOLLOW)||!restore_same(&retained,&named)||fsync(w)||fsync(parent)){errno=EIO;goto done;}
  result=0;goto done;
 }
 if(savedfd<0){
  if(restore_verify(current,geteuid(),expected,length,1,&live)||fstatat(parent,base,&named,AT_SYMLINK_NOFOLLOW)||!restore_same(&live,&named))goto done;
  if(linkat(parent,base,w,"superseded",0))goto done;changed=1;
  savedfd=openat(w,"superseded",O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(savedfd<0)goto done;
 }
 if(restore_verify(current,geteuid(),expected,length,2,&live)||restore_verify(savedfd,geteuid(),expected,length,2,&retained)||!restore_same(&live,&retained)||
    fstatat(parent,base,&named,AT_SYMLINK_NOFOLLOW)||!restore_same(&live,&named)||fstatat(w,"superseded",&after,AT_SYMLINK_NOFOLLOW)||!restore_same(&retained,&after)||fsync(w)){errno=EIO;goto done;}
#ifdef HC_RESTORE_TEST_HOOK
 {extern void hc_test_restore_hook(int);hc_test_restore_hook(3);}
#endif
 if(fstatat(parent,base,&named,AT_SYMLINK_NOFOLLOW)||!restore_same(&live,&named)||unlinkat(parent,base,0))goto done;changed=1;
#ifdef HC_RESTORE_TEST_HOOK
 {extern void hc_test_restore_hook(int);hc_test_restore_hook(4);}
#endif
 if(fsync(parent)||fsync(w)||restore_verify(savedfd,geteuid(),expected,length,1,&retained)||fstatat(w,"superseded",&named,AT_SYMLINK_NOFOLLOW)||!restore_same(&retained,&named)){errno=EIO;goto done;}
 if(fstatat(parent,base,&named,AT_SYMLINK_NOFOLLOW)==0||errno!=ENOENT){errno=EIO;goto done;}
 result=0;
 done: {int saved=errno;if(current>=0&&close(current)&&result==0){result=-1;saved=EIO;}if(savedfd>=0&&close(savedfd)&&result==0){result=-1;saved=EIO;}if(w>=0&&close(w)&&result==0){result=-1;saved=EIO;}free(entries);if(result<0&&changed)result=-2;errno=saved;return result;}
}
