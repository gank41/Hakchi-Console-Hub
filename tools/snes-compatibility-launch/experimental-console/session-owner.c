#include "session-owner.h"
#include "hc-intent-v2.h"
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* One frontend process owns one session. Registration and shutdown are main
 * thread only; the object remains borrowed through worker joins and recovery. */
static HCSessionOwner *frontend_owner;
/* Borrowed for main-thread frontend integration only; owner lifetime is unchanged. */
HCSessionOwner *hc_session_frontend_current_owner(void){return frontend_owner;}
static int reserved_region_prefix(const char *name,const char *prefix){
 for(;*prefix;name++,prefix++){unsigned char c=(unsigned char)*name;if(!c)return 0;if(c>='A'&&c<='Z')c=(unsigned char)(c+32);if(c!=(unsigned char)*prefix)return 0;}return 1;
}
static int valid_region_name(const char *name){
 size_t i=0;if(!name||!name[0])return 0;
 for(;i<64&&name[i];i++){unsigned char c=(unsigned char)name[i];if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='-'||c=='_'||c=='.'))return 0;}
 return i>0&&i<64&&strcmp(name,".")&&strcmp(name,"..")&&!reserved_region_prefix(name,"intent")&&!reserved_region_prefix(name,"checkpoint-");
}
static int matches_parent(int parent,const char *identity){
 char path[1024];struct stat held,mapped;const char *last=strrchr(identity,'/');
 if(!last||!last[1])return -1;
 size_t length=(size_t)(last-identity);if(!length)length=1;
 if(length>=sizeof path)return -1;
 memcpy(path,identity,length);path[length]='\0';
 int fd=open(path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return -1;
 int ok=fstat(parent,&held)==0&&fstat(fd,&mapped)==0&&S_ISDIR(held.st_mode)&&S_ISDIR(mapped.st_mode)&&held.st_dev==mapped.st_dev&&held.st_ino==mapped.st_ino;
 int closed=close(fd);if(!ok||closed!=0){errno=EINVAL;return -1;}return 0;
}
static int same_ascii_name(const char *a,const char *b){
 for(;;a++,b++){unsigned char x=(unsigned char)*a,y=(unsigned char)*b;if(x>='A'&&x<='Z')x=(unsigned char)(x+32);if(y>='A'&&y<='Z')y=(unsigned char)(y+32);if(x!=y)return 0;if(!x)return 1;}
}
int hc_session_validate_regions(const HCSessionExpected *r,size_t n){
 if(!r||!n||n>16){errno=EINVAL;return -1;}
 struct stat stats[16];
 for(size_t i=0;i<n;i++){
  if(r[i].parent<0||!r[i].identity||r[i].identity[0]!='/'||strnlen(r[i].identity,1024)>=1024){errno=EINVAL;return -1;}
  const char *name=strrchr(r[i].identity,'/');
  if(!name||!valid_region_name(name+1)||fstat(r[i].parent,&stats[i])||matches_parent(r[i].parent,r[i].identity)){errno=EINVAL;return -1;}
  for(size_t j=0;j<i;j++){
   const char *other=strrchr(r[j].identity,'/');
   if(stats[i].st_dev==stats[j].st_dev&&stats[i].st_ino==stats[j].st_ino&&same_ascii_name(name+1,other+1)){errno=EINVAL;return -1;}
  }
 }
 return 0;
}
static int no_sram_publish(void *c,const char *p,const void *b,size_t n){(void)c;(void)p;(void)b;(void)n;return -1;}
static bool no_sram_validate(void *c,const char *p){(void)c;(void)p;return false;}
static int no_sram_worker(void *c,const char *p){(void)c;(void)p;return -1;}
static void hex_nonce(const uint8_t nonce[16],char output[33]){
 static const char digits[]="0123456789abcdef";
 for(size_t i=0;i<16;i++){output[2*i]=digits[nonce[i]>>4];output[2*i+1]=digits[nonce[i]&15];}output[32]='\0';
}
/* Called with router and owner locks held. The journal must be durable before
 * the corresponding target workspace is created. Failed intents remain. */
static int record_nonce(HCSessionNonceContext *context,HCIV2Kind kind,uint8_t out[16]){
 HCSessionOwner *s=context->owner;size_t i=context->index;uint8_t next[16];char hex[33],workspace[44];
 if(!s||i>=s->count||hc_nonce_sequence_next(&s->nonces,next)!=0)return -1;
 hex_nonce(next,hex);memcpy(workspace,"checkpoint-",11);memcpy(workspace+11,hex,33);
 const char *name=strrchr(s->paths[i],'/');
 if(!name||hciv2_create(s->parents[i],s->journal_session,workspace,name+1,kind)!=0)return -1;
#ifdef HC_SESSION_TEST_AFTER_INTENT
 {extern void hc_test_after_session_intent(void);hc_test_after_session_intent();}
#endif
 memcpy(out,next,16);return 0;
}
static int periodic_nonce(void *context,uint8_t out[16]){return record_nonce(context,HCIV2_PERIODIC,out);}
static int retire_periodic_intent(void *context,const char *workspace){
 HCSessionNonceContext *c=context;HCSessionOwner *s=c?c->owner:NULL;
 if(!s||c->index>=s->count){errno=EINVAL;return -1;}
 const char *name=strrchr(s->paths[c->index],'/');if(!name||!name[1]){errno=EINVAL;return -1;}
 return hciv2_remove_retired(s->parents[c->index],s->journal_session,workspace,name+1);
}
/* The owner is deliberately one-shot. Every failure preserves partial
 * state; a future recovery coordinator must inspect it before disposal. */
static int prepare_session(void *context,uint64_t epoch,const HCSramRegion *regions,size_t n){
 HCSessionOwner *s=context;HCPeriodicOwner *active[16];size_t active_count=0;
 if(!s||s->state!=1)return -1;
 s->state=2;
 if(!epoch||epoch!=s->expected_epoch||!regions||n!=s->count)goto fail;
 for(size_t i=0;i<n;i++){
  if(!regions[i].path||strcmp(regions[i].path,s->paths[i])||regions[i].type!=s->types[i])goto fail;
  size_t retained=0;
  if(matches_parent(s->parents[i],s->paths[i])!=0||hc_periodic_recovery_status(s->parents[i],s->uid,&retained)!=0)goto fail;
  if(retained){errno=EBUSY;goto fail;}
  if(regions[i].size)active_count++;
 }
 if(!active_count){
  if(hc_frontend_bind_sram_session(s->final_ptrs,n,no_sram_publish,no_sram_validate,no_sram_worker,no_sram_worker,s)!=0)goto fail;
  s->state=3;return 0;
 }
 if(hc_nonce_sequence_init(&s->nonces)!=0)goto fail;
 active_count=0;
 /* All periodic owners scan before any final workspace is created. */
 for(size_t i=0;i<n;i++)if(regions[i].size){
  const char *name=strrchr(s->paths[i],'/');
  s->owners[i]=calloc(1,sizeof(*s->owners[i]));if(!s->owners[i]||!name||!name[1])goto fail;
  s->nonce_contexts[i].owner=s;s->nonce_contexts[i].index=i;
  if(hc_periodic_owner_init(s->owners[i],s->parents[i],s->uid,s->paths[i],name+1,periodic_nonce,&s->nonce_contexts[i])!=0||
     hc_periodic_owner_set_retired_intent_cleanup(s->owners[i],retire_periodic_intent,&s->nonce_contexts[i])!=0)goto fail;
  active[active_count++]=s->owners[i];
 }
 if(hc_periodic_router_init(&s->router,active,active_count)!=0)goto fail;
 if(s->retention==HC_RETENTION_KEEP_PREVIOUS&&hc_periodic_router_enable_reclaim(&s->router)!=0)goto fail;
 for(size_t i=0;i<n;i++)if(regions[i].size){
  uint8_t nonce[16];const char *name=strrchr(s->paths[i],'/');
  if(record_nonce(&s->nonce_contexts[i],HCIV2_FINAL,nonce)!=0||hc_autosave_target_prepare(&s->finals[i],s->parents[i],s->uid,nonce,s->paths[i],name+1)!=0)goto fail;
  s->final_ptrs[i]=&s->finals[i];
 }
 if(hc_frontend_bind_sram_session(s->final_ptrs,n,hc_periodic_router_publish,hc_periodic_router_can_publish,hc_periodic_router_worker_acquire,hc_periodic_router_worker_release,&s->router)!=0)goto fail;
 s->state=3;return 0;
fail:
 s->state=4;return -1;
}

int hc_session_owner_install(HCSessionOwner *s,uid_t uid,const HCSessionExpected *expected,size_t count,HCSessionRetention retention,const uint8_t session[16],uint64_t expected_epoch){
 int owned[16];for(size_t i=0;i<16;i++)owned[i]=-1;
 unsigned any=0;if(session)for(size_t i=0;i<16;i++)any|=session[i];
 if(!s||s->state||frontend_owner||!expected||!count||count>16||!session||!any||!expected_epoch||
    (retention!=HC_RETENTION_KEEP_ALL&&retention!=HC_RETENTION_KEEP_PREVIOUS))return -1;
 if(hc_session_validate_regions(expected,count)!=0)return -1;
 /* Validate and copy inputs before registering a persistent callback. */
 for(size_t i=0;i<count;i++){
  if(expected[i].parent<0||!expected[i].identity||expected[i].identity[0]!='/')return -1;
  size_t retained=0;if(hc_periodic_recovery_status(expected[i].parent,uid,&retained)!=0)return -1;
  if(retained){errno=EBUSY;return -1;}
  size_t length=strnlen(expected[i].identity,sizeof s->paths[i]);
  if(!length||length>=sizeof s->paths[i])return -1;
  const char *name=strrchr(expected[i].identity,'/');if(!name||!valid_region_name(name+1))return -1;
  for(size_t j=0;j<i;j++)if(!strcmp(expected[i].identity,expected[j].identity))return -1;
 }
 for(size_t i=0;i<count;i++){
  size_t retained=0;owned[i]=fcntl(expected[i].parent,F_DUPFD_CLOEXEC,3);
  if(owned[i]<0||matches_parent(owned[i],expected[i].identity)!=0||hc_periodic_recovery_status(owned[i],uid,&retained)!=0)goto close_owned;
  if(retained){errno=EBUSY;goto close_owned;}
 }
 s->uid=uid;s->count=count;s->retention=retention;s->expected_epoch=expected_epoch;memcpy(s->session_token,session,16);hex_nonce(session,s->journal_session);
 for(size_t i=0;i<count;i++){s->parents[i]=owned[i];s->types[i]=expected[i].type;strcpy(s->paths[i],expected[i].identity);}
 s->state=1;if(hc_register_sram_preparer(prepare_session,s)!=0){s->state=4;goto close_owned;}frontend_owner=s;return 0;
close_owned:
 {int saved=errno;for(size_t i=0;i<count;i++){if(owned[i]>=0)close(owned[i]);if(s->state==4)s->parents[i]=-1;}errno=saved;return -1;}
}
int hc_session_recovery_inventory(const HCSessionExpected *expected,size_t expected_count,size_t index,const uint8_t session[16],HCIV2Entry *entries,size_t capacity,size_t *count){
 unsigned any=0;if(session)for(size_t i=0;i<16;i++)any|=session[i];
 if(!expected||!expected_count||expected_count>16||index>=expected_count||!session||!any||!count||(!entries&&capacity)){errno=EINVAL;return -1;}
 if(hc_session_validate_regions(expected,expected_count)!=0)return -1;
 for(size_t i=0;i<expected_count;i++){
  if(expected[i].parent<0||!expected[i].identity||expected[i].identity[0]!='/'||strnlen(expected[i].identity,1024)>=1024){errno=EINVAL;return -1;}
  const char *name=strrchr(expected[i].identity,'/');
  if(!name||!valid_region_name(name+1)||matches_parent(expected[i].parent,expected[i].identity))return -1;
  for(size_t j=0;j<i;j++)if(!strcmp(expected[i].identity,expected[j].identity)){errno=EINVAL;return -1;}
 }
 struct stat parent;if(fstat(expected[index].parent,&parent))return -1;
 char journal_session[33];hex_nonce(session,journal_session);
 size_t bound=capacity<4096?capacity:4096,n=0;
 HCIV2Entry *snapshot=bound?calloc(bound,sizeof(*snapshot)):NULL;
 if(bound&&!snapshot)return -1;
 if(hciv2_inventory(expected[index].parent,journal_session,snapshot,bound,&n)){free(snapshot);return -1;}
 for(size_t k=0;k<n;k++){
  int found=0;
  for(size_t i=0;i<expected_count;i++){
   struct stat candidate;const char *name=strrchr(expected[i].identity,'/');
   if(!name||fstat(expected[i].parent,&candidate)||matches_parent(expected[i].parent,expected[i].identity)){free(snapshot);errno=EIO;return -1;}
   if(candidate.st_dev==parent.st_dev&&candidate.st_ino==parent.st_ino&&!strcmp(name+1,snapshot[k].region))found++;
  }
  if(found!=1){free(snapshot);errno=EPROTO;return -1;}
 }
 if(n)memcpy(entries,snapshot,n*sizeof(*snapshot));*count=n;free(snapshot);return 0;
}
int hc_session_owner_inventory(HCSessionOwner *s,size_t index,HCIV2Entry *entries,size_t capacity,size_t *count){
 if(!s||!s->state||!s->count||s->count>16){errno=EINVAL;return -1;}
 HCSessionExpected expected[16];
 for(size_t i=0;i<s->count;i++)expected[i]=(HCSessionExpected){s->parents[i],s->paths[i],s->types[i]};
 return hc_session_recovery_inventory(expected,s->count,index,s->session_token,entries,capacity,count);
}
int hc_session_owner_begin_worker_shutdown(HCSessionOwner *s){
 if(!s||s->state!=3){errno=EINVAL;return -1;}
 if(s->router.ready&&hc_periodic_router_close_workers(&s->router))return -1;
 s->workers_closing=1;return 0;
}
int hc_session_owner_workers_drained(HCSessionOwner *s){
 if(!s||s->state!=3||!s->workers_closing)return 0;
 return s->router.ready?hc_periodic_router_workers_drained(&s->router):1;
}
int hc_session_frontend_begin_worker_shutdown(void){return hc_session_owner_begin_worker_shutdown(frontend_owner);}
int hc_session_frontend_workers_drained(void){return hc_session_owner_workers_drained(frontend_owner);}
