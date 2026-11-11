#include "recovery-clock-wire.h"
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
/* This parses correlation data, not authorization. Output remains unchanged
 * on error and the evidence pointer borrows the input buffer. */
static int decode_recovery(const void *buffer,size_t length,HCClockRecoveryRequest *out,const char magic[8]){
 if(!buffer||!out||length<186||length>185+256u*1024u){errno=EINVAL;return -1;}
 const unsigned char *p=buffer;HCClockRecoveryRequest value={0};
 if(memcmp(p,magic,8)||hc_launch_request_decode(p+8,HC_LAUNCH_REQUEST_SIZE,&value.request)||memcmp(p+115,"checkpoint-",11)){errno=EINVAL;return -1;}
 for(size_t i=126;i<158;i++)if(!((p[i]>='0'&&p[i]<='9')||(p[i]>='a'&&p[i]<='f'))){errno=EINVAL;return -1;}
 memcpy(value.workspace,p+115,43);value.workspace[43]=0;
 if(p[158]!=HC_RECOVERY_ORIGINAL_PRESENT&&p[158]!=HC_RECOVERY_ORIGINAL_ABSENT){errno=EINVAL;return -1;}
 value.original=(HCRecoveryOriginal)p[158];uint32_t n=(uint32_t)p[159]|((uint32_t)p[160]<<8)|((uint32_t)p[161]<<16)|((uint32_t)p[162]<<24);
 if(!n||n>128u*1024u||length<185+(size_t)n){errno=EINVAL;return -1;}
 value.evidence=p+163;value.evidence_length=n;size_t pos=163+(size_t)n;
 if(p[pos]>1){errno=EINVAL;return -1;}value.current_present=p[pos++];
 uint32_t current=(uint32_t)p[pos]|((uint32_t)p[pos+1]<<8)|((uint32_t)p[pos+2]<<16)|((uint32_t)p[pos+3]<<24);pos+=4;
 if(current>128u*1024u||length!=pos+(size_t)current+17||(!current)!=(!value.current_present)){errno=EINVAL;return -1;}
 value.current=p+pos;value.current_length=current;
 if(value.original==HC_RECOVERY_ORIGINAL_ABSENT&&(!value.current_present||current!=n||memcmp(value.evidence,value.current,n))){errno=EINVAL;return -1;}
 pos+=(size_t)current;for(unsigned i=0;i<8;i++){value.device|=(uint64_t)p[pos+i]<<(8*i);value.inode|=(uint64_t)p[pos+8+i]<<(8*i);}
 if(!value.inode||(p[pos+16]!=HCIV2_PERIODIC&&p[pos+16]!=HCIV2_FINAL)){errno=EINVAL;return -1;}
 value.intent_kind=(HCIV2Kind)p[pos+16];
 *out=value;return 0;
}
int hc_clock_recovery_decode(const void *b,size_t n,HCClockRecoveryRequest *o){return decode_recovery(b,n,o,"HCRST31\0");}
int hc_battery_recovery_decode(const void *b,size_t n,HCBatteryRecoveryRequest *o){return decode_recovery(b,n,o,"HCRST30\0");}
/* The caller must exclude writers across this comparison and restore. */
static int execute_recovery(int profiles,const char *root,uid_t uid,const HCClockRecoveryRequest *req,size_t region){
 int lock=hc_recovery_lock_game(profiles,uid,&req->request,req->device,req->inode);if(lock<0)return -1;
 HCRecoveryLiveSave *live=calloc(1,sizeof *live);if(!live){int saved=errno;close(lock);errno=saved;return -1;}
 HCRecoveryObservation selection;
 int bad=hc_recovery_observe_game(profiles,root,uid,&req->request,region,&selection)||selection.device!=req->device||selection.inode!=req->inode;
 size_t matched=0;
 if(!bad)for(size_t i=0;i<selection.entry_count;i++)if(!strcmp(selection.entries[i].workspace,req->workspace)){
  if(!selection.entries[i].workspace_present||selection.entries[i].kind!=req->intent_kind||strcmp(selection.entries[i].region,region?"battery.rtc":"battery.srm"))bad=1;matched++;
 }
 if(matched!=1)bad=1;
 if(!bad)bad=hc_recovery_read_current_game(profiles,root,uid,&req->request,region,live)||live->device!=req->device||live->inode!=req->inode||live->present!=req->current_present||live->length!=req->current_length||
         (live->present&&memcmp(live->bytes,req->current,live->length));
 free(live);if(bad){close(lock);errno=ESTALE;return -1;}
 int result=hc_recovery_restore_game(profiles,root,uid,&req->request,region,req->workspace,req->original,req->evidence,req->evidence_length),saved=errno;
 if(close(lock)){if(result==0||result==-2)result=-2;else result=-1;saved=EIO;}errno=saved;return result;
}
/* Caller must independently authenticate the game, session, original evidence,
 * current bytes for absent recovery, stopped writers and exclusive root. */
int hc_clock_recovery_execute(int profiles,const char *root,uid_t uid,const void *buffer,size_t length){
 HCClockRecoveryRequest req;if(hc_clock_recovery_decode(buffer,length,&req))return -1;
 return execute_recovery(profiles,root,uid,&req,1);
}
/* Checks only that this clock workspace is in the current read-only inventory.
 * The evidence bytes and all recovery authority remain unverified. */
static int inspect_recovery(int profiles,const char *root,uid_t uid,const void *buffer,size_t length,HCRecoveryObservation *out,int battery){
 HCClockRecoveryRequest req;HCRecoveryObservation observation;size_t matched=0;
 if(!out){errno=EINVAL;return -1;}
 if((battery?hc_battery_recovery_decode(buffer,length,&req):hc_clock_recovery_decode(buffer,length,&req))||hc_recovery_observe_game(profiles,root,uid,&req.request,battery?0:1,&observation))return -1;
 if(req.device!=observation.device||req.inode!=observation.inode){errno=ESTALE;return -1;}
 for(size_t i=0;i<observation.entry_count;i++)if(!strcmp(observation.entries[i].workspace,req.workspace)){
  if(strcmp(observation.entries[i].region,battery?"battery.srm":"battery.rtc")||!observation.entries[i].workspace_present||observation.entries[i].kind!=req.intent_kind){errno=EINVAL;return -1;}matched++;
 }
 if(matched!=1){errno=ENOENT;return -1;}*out=observation;return 0;
}
int hc_clock_recovery_inspect(int p,const char *r,uid_t u,const void *b,size_t n,HCRecoveryObservation *o){return inspect_recovery(p,r,u,b,n,o,0);}
int hc_battery_recovery_inspect(int p,const char *r,uid_t u,const void *b,size_t n,HCRecoveryObservation *o){return inspect_recovery(p,r,u,b,n,o,1);}
/* Experimental primitive only; no console command exposes this write. */
int hc_battery_recovery_execute(int profiles,const char *root,uid_t uid,const void *buffer,size_t length){
 HCBatteryRecoveryRequest req;if(hc_battery_recovery_decode(buffer,length,&req))return -1;
 return execute_recovery(profiles,root,uid,&req,0);
}
