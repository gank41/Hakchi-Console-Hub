#define _POSIX_C_SOURCE 200809L
#include "stock-runtime-bridge.h"
#include "nonce-sequence.h"
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
int hc_stock_game_prepare_runtime(HCStockGameSession *s,HCConsoleRuntime *r,HCConsoleGame *g,int argc,const char *const argv[],const char *profiles,int save,int stage,const char *name,size_t size){
 unsigned char frame[HC_LAUNCH_REQUEST_SIZE],nonce[16];char hex[33],workspace[44],binding[41];struct stat st;
 static const char digits[]="0123456789abcdef";
 if(!s||!r||!g||r->attempted||r->stock_claimed||(r->save_lock!=-1&&r->save_lock<3)||r->workspace<0||r->save<0||r->image<0||r->report[0]<0||r->report[1]<0||r->exitpipe[0]<0||r->exitpipe[1]<0||r->exit_pin<0||r->supervisor||hc_launch_request_encode(&r->request,frame)||strcmp(r->request.game,g->command.game)||strcmp(r->request.digest,g->command.digest)){errno=EINVAL;return -1;}
 for(size_t i=0;i<16;i++){hex[2*i]=digits[r->request.session[i]>>4];hex[2*i+1]=digits[r->request.session[i]&15];}hex[32]=0;
 if(snprintf(workspace,sizeof workspace,"checkpoint-%s",hex)!=(int)(sizeof workspace-1)||strcmp(workspace,r->workspace_name)||fstat(r->workspace,&st)||!S_ISDIR(st.st_mode)||st.st_uid!=geteuid()||(st.st_mode&0777)!=0700){errno=EINVAL;return -1;}
 if(snprintf(binding,sizeof binding,"bind-%s",hex)!=37){errno=EINVAL;return -1;}
 /* A rejected stage has not been handed to the save session. Keep the
  * untouched runtime eligible for the existing unstarted cleanup path. */
 if(hc_stock_save_validate_stage(stage,save,name,size))return -1;
 HCNonceSequence seq=HC_NONCE_SEQUENCE_INITIALIZER;if(hc_nonce_sequence_init(&seq))return -1;
 int result=hc_nonce_sequence_next(&seq,nonce),saved=errno;
 if(hc_nonce_sequence_destroy(&seq)&&!result){result=-1;saved=errno;}
 if(result){errno=saved;return -1;}
 if(!memcmp(nonce,r->request.session,16)){errno=EIO;return -1;}
 /* Make the session discoverable before the save binding or intent can be
  * created. This attempt is single-use even if the record write fails. */
 r->stock_claimed=1;
 if(hc_console_game_prepare_manager_record(g,r,argc,argv))return -1;
 /* From this point the session may retain references or recovery evidence,
  * even if preparation fails. Never discard the runtime as unused. */
 r->claimed=1;
 if(r->save_lock>=0)return hc_stock_game_prepare_with_lock(s,g,argc,argv,profiles,save,stage,name,size,binding,r->request.session,r->request.epoch,nonce,r->save_lock);
 return hc_stock_game_prepare(s,g,argc,argv,profiles,save,stage,name,size,binding,r->request.session,r->request.epoch,nonce);
}

int hc_stock_game_prepare_detected(HCStockGameSession *s,HCConsoleRuntime *r,HCConsoleGame *g,int argc,const char *const argv[],const char *profiles,int save,int stage,const char *name,HCSizeProbe *probe,HCVerifiedLaunch *expected_core){
 if(!probe||!g||!probe->complete||!probe->verified||probe->consumed||probe->failed||probe->rom!=&g->rom||probe->core!=expected_core||probe->size>4u*1024u*1024u||
    hc_verified_launch_recheck(probe->program)||hc_verified_launch_recheck(probe->core)||hc_verified_launch_recheck(probe->rom)){errno=EINVAL;return -1;}
 /* Any attempt can leave recovery evidence; never reuse the probe result. */
 probe->consumed=1;
 int result=hc_stock_game_prepare_runtime(s,r,g,argc,argv,profiles,save,stage,name,probe->size?probe->size:32768);
 if(!result){memcpy(s->detected_core_sha,expected_core->sha256,sizeof s->detected_core_sha);s->detected_no_sram=probe->size==0;}
 return result;
}
