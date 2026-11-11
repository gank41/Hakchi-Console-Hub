#include "periodic-owner.h"
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <dirent.h>
#include "mbedtls/sha256.h"
static int digest_file(int fd,uint64_t length,uint8_t out[32]){
 if(length>128u*1024u*1024u)return -1;
 mbedtls_sha256_context h;mbedtls_sha256_init(&h);if(mbedtls_sha256_starts(&h,0)!=0){mbedtls_sha256_free(&h);return -1;}
 uint8_t buf[4096];uint64_t offset=0;int ok=1;
 while(offset<length){size_t n=(size_t)(length-offset);if(n>sizeof buf)n=sizeof buf;ssize_t r=pread(fd,buf,n,(off_t)offset);if(r<0&&errno==EINTR)continue;if(r<=0||mbedtls_sha256_update(&h,buf,(size_t)r)!=0){ok=0;break;}offset+=(uint64_t)r;}
 if(ok&&mbedtls_sha256_finish(&h,out)!=0)ok=0;mbedtls_sha256_free(&h);return ok?0:-1;
}
static int valid_component(const char *p){size_t i=0;if(!p||!p[0]||!strcmp(p,".")||!strcmp(p,".."))return 0;for(;p[i]&&i<127;i++){unsigned char c=(unsigned char)p[i];if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='_'||c=='-'||c=='.'))return 0;}return i>0&&i<128&&!p[i];}
/* No cleanup is attempted here. Unknown retained workspaces require a future
 * recovery flow and must not be silently reused after a process restart. */
int hc_periodic_recovery_status(int parent,uid_t owner,size_t *count){
 struct stat st;int flags=fcntl(parent,F_GETFD);
 if(!count||flags<0||!(flags&FD_CLOEXEC)||fstat(parent,&st)!=0||!S_ISDIR(st.st_mode)||st.st_uid!=owner||(st.st_mode&0777)!=0700){errno=EINVAL;return -1;}
 int fd=openat(parent,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return -1;
 DIR *dir=fdopendir(fd);if(!dir){close(fd);return -1;}
 int status=0,saved=0;size_t seen=0,retained=0;struct dirent *entry;
 for(;;){errno=0;entry=readdir(dir);if(!entry){if(errno){status=-1;saved=errno;}break;}
  if(++seen>4096){status=-1;saved=EOVERFLOW;break;}
  if(!strncmp(entry->d_name,"checkpoint-",11)||!strncmp(entry->d_name,"intent",6))retained++;
 }
 if(closedir(dir)!=0&&status==0){status=-1;saved=errno;}
 if(status<0)errno=saved;else *count=retained;return status;
}
static int hash_previous(HCPeriodicOwner *o,size_t slot,uint8_t digest[32],struct stat *out){
 struct stat path,held;int fd;
 if(fstatat(o->targets[slot].workspace,"previous",&path,AT_SYMLINK_NOFOLLOW)!=0||!S_ISREG(path.st_mode)||path.st_uid!=o->owner||path.st_nlink!=1||(path.st_mode&0022)||path.st_size<0||(uint64_t)path.st_size>128u*1024u*1024u)return -1;
 fd=openat(o->targets[slot].workspace,"previous",O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return -1;
 int ok=fstat(fd,&held)==0&&S_ISREG(held.st_mode)&&held.st_dev==path.st_dev&&held.st_ino==path.st_ino&&held.st_size==path.st_size&&held.st_uid==o->owner&&held.st_nlink==1&&!(held.st_mode&0022)&&digest_file(fd,(uint64_t)held.st_size,digest)==0;
 if(close(fd)!=0)ok=0;if(!ok)return -1;*out=held;return 0;
}
static int verify_previous(HCPeriodicOwner *o,size_t slot){
 struct stat s;uint8_t digest[32];
 if(!o->previous_present[slot]){if(fstatat(o->targets[slot].workspace,"previous",&s,AT_SYMLINK_NOFOLLOW)==0||errno!=ENOENT)return -1;return 0;}
 return hash_previous(o,slot,digest,&s)==0&&(uint64_t)s.st_dev==o->previous_device[slot]&&(uint64_t)s.st_ino==o->previous_inode[slot]&&(uint64_t)s.st_size==o->previous_size[slot]&&!memcmp(digest,o->previous_digest[slot],32)?0:-1;
}
static int expected_workspace_entries(int workspace,int previous_present){
 int fd=openat(workspace,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return -1;
 DIR *d=fdopendir(fd);if(!d){close(fd);return -1;}int ok=1,found=0;struct dirent *e;errno=0;
 while((e=readdir(d))!=NULL){if(!strcmp(e->d_name,".")||!strcmp(e->d_name,".."))continue;if(previous_present&&!strcmp(e->d_name,"previous")&&!found){found=1;continue;}ok=0;break;}
 if(errno!=0)ok=0;if(closedir(d)!=0)ok=0;return ok&&found==!!previous_present?0:-1;
}
int hc_periodic_owner_init(HCPeriodicOwner *o,int p,uid_t u,const char *i,const char *d,HCNonceSource n,void *x){
 struct stat parent,mapped;char dirname[1024];size_t len;const char *last;int flags,mappedfd;
 if(!o||o->active||!i||i[0]!='/'||!valid_component(d)||!n||!x){errno=EINVAL;return -1;}
 len=strnlen(i,sizeof dirname);last=strrchr(i,'/');flags=fcntl(p,F_GETFD);
 if(len>=sizeof dirname||!last||strcmp(last+1,d)||flags<0||!(flags&FD_CLOEXEC)||fstat(p,&parent)!=0||!S_ISDIR(parent.st_mode)||parent.st_uid!=u||(parent.st_mode&0777)!=0700){errno=EINVAL;return -1;}
 size_t nparent=(size_t)(last-i);if(!nparent)nparent=1;memcpy(dirname,i,nparent);dirname[nparent]='\0';
 mappedfd=open(dirname,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(mappedfd<0)return -1;
 int match=fstat(mappedfd,&mapped)==0&&mapped.st_dev==parent.st_dev&&mapped.st_ino==parent.st_ino;close(mappedfd);if(!match){errno=EINVAL;return -1;}
 size_t retained=0;if(hc_periodic_recovery_status(p,u,&retained)!=0)return -1;
 if(retained){errno=EBUSY;return -1;}
 if(pthread_mutex_init(&o->lock,NULL)!=0){errno=EIO;return -1;}
 o->parent=p;o->owner=u;o->nonce=n;o->nonce_context=x;memcpy(o->identity,i,len+1);strcpy(o->destination,d);o->active=1;return 0;
}
int hc_periodic_owner_set_retired_intent_cleanup(HCPeriodicOwner *o,HCRetiredIntentCleanup fn,void *context){
 if(!o||!o->active||o->routed||o->count||o->retire_intent||!fn||!context){errno=EINVAL;return -1;}
 o->retire_intent=fn;o->retire_context=context;return 0;
}
static int periodic_owner_publish(void *context,const char *path,const void *bytes,size_t size){
 HCPeriodicOwner *o=context;uint8_t nonce[16];unsigned nonzero=0;int result=-2;
 if(!o||!o->active||!path||!bytes||!size)return -1;
 if(pthread_mutex_lock(&o->lock)!=0)return -2;
 if(o->failed)goto done;
 if(strcmp(path,o->identity)){o->failed=1;goto done;}
 if(o->count>=16){o->failed=1;goto done;}
 if(o->nonce(o->nonce_context,nonce)!=0){o->failed=1;goto done;}
 for(size_t i=0;i<16;i++)nonzero|=nonce[i];
 if(!nonzero){o->failed=1;goto done;}
 for(size_t i=0;i<o->count;i++)if(!memcmp(o->attempted_nonces[i],nonce,16)){o->failed=1;goto done;}
 size_t slot=o->count++;memcpy(o->attempted_nonces[slot],nonce,16);o->outcomes[slot]=-4;
 HCAutosaveTarget *target=&o->targets[slot];
 if(hc_autosave_target_prepare(target,o->parent,o->owner,nonce,o->identity,o->destination)!=0){o->failed=1;goto done;}
 if(hc_autosave_target_acquire(target)!=0){o->failed=1;goto done;}
 int write_result=hc_autosave_target_write(target,path,bytes,size);int release_result=hc_autosave_target_release(target);
 o->outcomes[slot]=write_result;
 if(write_result!=0||release_result!=0){o->failed=1;goto done;}
 if(mbedtls_sha256(bytes,size,o->written_digest[slot],0)!=0){o->outcomes[slot]=-2;o->failed=1;goto done;}
 o->written_size[slot]=size;
 struct stat previous;uint8_t previous_hash[32];
 if(fstatat(target->workspace,"previous",&previous,AT_SYMLINK_NOFOLLOW)==0){
  if(hash_previous(o,slot,previous_hash,&previous)!=0){o->outcomes[slot]=-2;o->failed=1;goto done;}
  if(slot>0){struct stat prior;
   if(o->outcomes[slot-1]!=0||fstat(o->targets[slot-1].temporary,&prior)!=0||
      prior.st_dev!=previous.st_dev||prior.st_ino!=previous.st_ino||
      (uint64_t)previous.st_size!=o->written_size[slot-1]||
      memcmp(previous_hash,o->written_digest[slot-1],32)){o->outcomes[slot]=-2;o->failed=1;goto done;}
  }
  o->previous_present[slot]=1;o->previous_device[slot]=(uint64_t)previous.st_dev;o->previous_inode[slot]=(uint64_t)previous.st_ino;o->previous_size[slot]=(uint64_t)previous.st_size;memcpy(o->previous_digest[slot],previous_hash,32);
 }else if(errno!=ENOENT||slot>0){o->outcomes[slot]=-2;o->failed=1;goto done;}
 result=0;
done:
 if(pthread_mutex_unlock(&o->lock)!=0)return -2;
 return result;
}
int hc_periodic_owner_publish(void *context,const char *path,const void *bytes,size_t size){
 HCPeriodicOwner *owner=context;if(!owner||owner->routed)return -2;
 return periodic_owner_publish(context,path,bytes,size);
}
int hc_periodic_router_init(HCPeriodicRouter *router,HCPeriodicOwner *const *owners,size_t count){
 if(!router||router->ready||!owners||!count||count>16)return -1;
 for(size_t i=0;i<count;i++){
  if(!owners[i]||!owners[i]->active||owners[i]->failed||owners[i]->routed)return -1;
  for(size_t j=0;j<i;j++)if(!strcmp(owners[i]->identity,owners[j]->identity))return -1;
 }
 if(pthread_mutex_init(&router->lock,NULL)!=0)return -1;
 memcpy(router->owners,owners,count*sizeof(*owners));for(size_t i=0;i<count;i++)owners[i]->routed=1;router->count=count;router->ready=1;return 0;
}
int hc_periodic_router_enable_reclaim(HCPeriodicRouter *router){
 if(!router||!router->ready)return -1;
 if(pthread_mutex_lock(&router->lock)!=0)return -1;
 int ok=!router->failed&&!router->auto_reclaim&&!router->started;
 if(ok)router->auto_reclaim=1;
 if(pthread_mutex_unlock(&router->lock)!=0)return -1;
 return ok?0:-1;
}
static int hc_periodic_owner_reclaim_oldest(HCPeriodicOwner *);
int hc_periodic_router_publish(void *context,const char *path,const void *bytes,size_t size){
 HCPeriodicRouter *router=context;if(!router||!router->ready||!path)return -2;
 if(pthread_mutex_lock(&router->lock)!=0)return -2;
 router->started=1;
 int result=-2;
 if(!router->failed){
  for(size_t i=0;i<router->count;i++)if(!strcmp(path,router->owners[i]->identity)){
   if(router->closing_workers&&!router->workers[i])break;
   HCPeriodicOwner *owner=router->owners[i];result=periodic_owner_publish(owner,path,bytes,size);
   /* Publication has already changed the destination: any cleanup failure
    * must be reported as uncertain, never as a safe-to-retry write failure. */
   if(result==0&&router->auto_reclaim&&owner->count>1&&hc_periodic_owner_reclaim_oldest(owner)!=0)result=-2;
   break;
  }
  if(result!=0)router->failed=1;
 }
 if(pthread_mutex_unlock(&router->lock)!=0)return -2;
 return result;
}
_Bool hc_periodic_router_can_publish(void *context,const char *path){
 HCPeriodicRouter *router=context;_Bool allowed=0;if(!router||!router->ready||!path)return 0;
 if(pthread_mutex_lock(&router->lock)!=0)return 0;
 if(!router->failed&&!router->closing_workers)for(size_t i=0;i<router->count;i++)if(!strcmp(path,router->owners[i]->identity)){
  HCPeriodicOwner *owner=router->owners[i];
  if(pthread_mutex_lock(&owner->lock)==0){allowed=!owner->failed;if(pthread_mutex_unlock(&owner->lock)!=0)allowed=0;}
  break;
 }
 if(pthread_mutex_unlock(&router->lock)!=0)return 0;
 return allowed;
}
static int hc_periodic_owner_reclaim_oldest(HCPeriodicOwner *o){
 struct stat latest,active,held,entry,previous;uint8_t digest[32];int result=-1,changed=0;
 if(!o||!o->active)return -1;
 if(pthread_mutex_lock(&o->lock)!=0)return -2;
 if(o->failed||o->count<2)goto done;
 size_t last=o->count-1;HCAutosaveTarget *old=&o->targets[0],*current=&o->targets[last];
 if(o->outcomes[0]!=0||o->outcomes[last]!=0||!old->ready||old->busy||!current->ready||current->busy)goto done;
 if(verify_previous(o,0)!=0||verify_previous(o,last)!=0||expected_workspace_entries(old->workspace,o->previous_present[0])!=0){o->failed=1;goto done;}
 if(fstat(current->temporary,&latest)!=0||fstatat(o->parent,o->destination,&active,AT_SYMLINK_NOFOLLOW)!=0||
    !S_ISREG(latest.st_mode)||!S_ISREG(active.st_mode)||latest.st_uid!=o->owner||active.st_uid!=o->owner||latest.st_nlink!=1||active.st_nlink!=1||
    (latest.st_mode&0777)!=0600||latest.st_size<0||(uint64_t)latest.st_size!=o->written_size[last]||
    latest.st_dev!=active.st_dev||latest.st_ino!=active.st_ino||fsync(current->temporary)!=0||
    digest_file(current->temporary,o->written_size[last],digest)!=0||memcmp(digest,o->written_digest[last],sizeof digest)||
    fstat(old->workspace,&held)!=0||fstatat(o->parent,old->workspace_name,&entry,AT_SYMLINK_NOFOLLOW)!=0||
    !S_ISDIR(held.st_mode)||!S_ISDIR(entry.st_mode)||held.st_uid!=o->owner||entry.st_uid!=o->owner||
    held.st_dev!=entry.st_dev||held.st_ino!=entry.st_ino){o->failed=1;goto done;}
 if(o->previous_present[0]){
  if(fstatat(old->workspace,"previous",&previous,AT_SYMLINK_NOFOLLOW)!=0||!S_ISREG(previous.st_mode)||previous.st_uid!=o->owner||
     (uint64_t)previous.st_dev!=o->previous_device[0]||(uint64_t)previous.st_ino!=o->previous_inode[0]){o->failed=1;goto done;}
  if(unlinkat(old->workspace,"previous",0)!=0){o->failed=1;goto done;}changed=1;
#ifdef HC_RECLAIM_TEST_HOOK
  { extern void hc_test_reclaim_after_unlink(void); hc_test_reclaim_after_unlink(); }
#endif
 }else if(fstatat(old->workspace,"previous",&previous,AT_SYMLINK_NOFOLLOW)==0||errno!=ENOENT){o->failed=1;goto done;}
 if(fsync(old->workspace)!=0||hc_autosave_target_close(old)!=0||unlinkat(o->parent,old->workspace_name,AT_REMOVEDIR)!=0||fsync(o->parent)!=0){o->failed=1;result=-2;goto done;}
#ifdef HC_RECLAIM_TEST_AFTER_WORKSPACE
 {extern void hc_test_reclaim_after_workspace(void);hc_test_reclaim_after_workspace();}
#endif
 if(o->retire_intent&&o->retire_intent(o->retire_context,old->workspace_name)!=0){o->failed=1;result=-2;goto done;}
 memmove(o->targets,o->targets+1,last*sizeof(o->targets[0]));memset(&o->targets[last],0,sizeof(o->targets[last]));
 memmove(o->attempted_nonces,o->attempted_nonces+1,last*sizeof(o->attempted_nonces[0]));
 memmove(o->outcomes,o->outcomes+1,last*sizeof(o->outcomes[0]));
 memmove(o->previous_present,o->previous_present+1,last*sizeof(o->previous_present[0]));
 memmove(o->previous_device,o->previous_device+1,last*sizeof(o->previous_device[0]));
 memmove(o->previous_inode,o->previous_inode+1,last*sizeof(o->previous_inode[0]));
 memmove(o->previous_size,o->previous_size+1,last*sizeof(o->previous_size[0]));
 memmove(o->previous_digest,o->previous_digest+1,last*sizeof(o->previous_digest[0]));
 memmove(o->written_size,o->written_size+1,last*sizeof(o->written_size[0]));
 memmove(o->written_digest,o->written_digest+1,last*sizeof(o->written_digest[0]));
 o->count=last;result=0;
done:
 if(result<0&&changed)result=-2;
 if(pthread_mutex_unlock(&o->lock)!=0)return -2;
 return result;
}
int hc_periodic_router_reclaim_oldest(HCPeriodicRouter *router,const char *path){
 if(!router||!router->ready||!path)return -1;
 if(pthread_mutex_lock(&router->lock)!=0)return -2;
 int result=-1;
 if(!router->failed)for(size_t i=0;i<router->count;i++)if(!strcmp(path,router->owners[i]->identity)){
  result=hc_periodic_owner_reclaim_oldest(router->owners[i]);
  if(router->owners[i]->failed)router->failed=1;
  break;
 }
 if(pthread_mutex_unlock(&router->lock)!=0)return -2;
 return result;
}
int hc_periodic_router_worker_acquire(void *context,const char *path){
 HCPeriodicRouter *r=context;int result=-1;
 if(!r||!r->ready||!path||pthread_mutex_lock(&r->lock)!=0)return -1;
 if(!r->failed&&!r->closing_workers)for(size_t i=0;i<r->count;i++)if(!strcmp(path,r->owners[i]->identity)){
  if(!r->workers[i]&&!r->owners[i]->failed){r->workers[i]=1;result=0;}
  break;
 }
 if(pthread_mutex_unlock(&r->lock)!=0)return -1;
 return result;
}
int hc_periodic_router_worker_release(void *context,const char *path){
 HCPeriodicRouter *r=context;int result=-1;
 if(!r||!r->ready||!path||pthread_mutex_lock(&r->lock)!=0)return -1;
 for(size_t i=0;i<r->count;i++)if(!strcmp(path,r->owners[i]->identity)){
  if(r->workers[i]==1){r->workers[i]=0;result=0;}
  break;
 }
 if(pthread_mutex_unlock(&r->lock)!=0)return -1;
 return result;
}
int hc_periodic_router_close_workers(HCPeriodicRouter *r){
 /* Publication holds this mutex across filesystem operations. Never stall the
  * frontend's deadline while a writer is inside one of those operations. */
 if(!r||!r->ready||pthread_mutex_trylock(&r->lock)!=0)return -1;
 r->closing_workers=1;
 return pthread_mutex_unlock(&r->lock)==0?0:-1;
}
int hc_periodic_router_workers_drained(HCPeriodicRouter *r){
 if(!r||!r->ready||pthread_mutex_trylock(&r->lock)!=0)return 0;
 int drained=r->closing_workers;
 for(size_t i=0;i<r->count;i++)if(r->workers[i])drained=0;
 if(pthread_mutex_unlock(&r->lock)!=0)return 0;
 return drained;
}
