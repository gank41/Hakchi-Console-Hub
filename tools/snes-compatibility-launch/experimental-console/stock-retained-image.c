#define _POSIX_C_SOURCE 200809L
#include "stock-retained-image.h"
#include "owned_directory.h"
#include "recovery-observer.h"
#include "screenshot-session-names.h"
#include "screenshot_png.h"
#include "nonce-sequence.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int capture_matches(HCStockGameSession *game,HCStockControlSession *control,HCStockScreenshotReceipt *capture){
 if(!game||!control||!capture||control->save!=&game->save||control->exit_owner.save!=&game->save||
    !control->screenshot||control->screenshot->context!=capture||capture->game!=game||capture->phase!=3||
    capture->checkpoint.phase!=HC_CP_READY||capture->checkpoint.sequence!=1||!capture->reader.done||!capture->image||!capture->image_length||capture->image_length>8u*1024u*1024u||
    memcmp(capture->checkpoint.session,game->token,16)||
    memcmp(capture->token,game->token,16)||capture->epoch!=game->epoch||!game->epoch||
    memcmp(capture->game_code,game->game,sizeof game->game)||memcmp(capture->rom_digest,game->rom.sha256,sizeof capture->rom_digest)||
    game->save.child.pid!=-1||game->save.child.input!=-1||hc_screenshot_png(capture->image,capture->image_length)||
    hc_stock_game_recheck(game)||hc_stock_control_refresh_finished(control)){errno=EINVAL;return -1;}
 return 0;
}
static int make_regions(HCStockGameSession *game,const uint8_t token[16],char clock[1024],char image[1024],HCScreenshotSessionNames *names,HCSessionExpected regions[3]){
 size_t n=strnlen(game->save.identity,sizeof game->save.identity);
 if(n<12||n>=sizeof game->save.identity||strcmp(game->save.identity+n-12,"/battery.srm")||hc_screenshot_session_names(token,names)){errno=EINVAL;return -1;}
 memcpy(clock,game->save.identity,n+1);memcpy(clock+n-3,"rtc",3);
 int z=snprintf(image,1024,"%.*s/%s",(int)(n-12),game->save.identity,names->retained_file);
 if(z<=0||z>=1024){errno=EINVAL;return -1;}
 int parent=game->save.target.parent;
 regions[0]=(HCSessionExpected){parent,game->save.identity,0};regions[1]=(HCSessionExpected){parent,clock,1};regions[2]=(HCSessionExpected){parent,image,100};return 0;
}
static int verify_retained(HCStockRetainedImage *retained,HCStockGameSession *game,HCStockScreenshotReceipt *capture,HCSessionExpected regions[3]){
 HCRecoveryObservation *observation=malloc(sizeof *observation);unsigned char *bytes=malloc(capture->image_length);size_t length=0;int ok=0;
 if(observation&&bytes&&!hc_recovery_collect_session_retained(game->save.target.parent,game->game,game->rom.sha256,game->token,game->epoch,regions,3,2,observation,bytes,capture->image_length,&length)&&
    length==capture->image_length&&!memcmp(bytes,capture->image,length))ok=1;
 free(observation);free(bytes);if(!ok){errno=EIO;return -1;}(void)retained;return 0;
}
int hc_stock_retained_image_prepare(HCStockRetainedImage *out,HCStockGameSession *game,HCStockControlSession *control,HCStockScreenshotReceipt *capture){
 HCSessionExpected regions[3];HCScreenshotSessionNames names;HCIV2Entry entries[16];size_t count=0;struct stat st;uint8_t nonce[16];HCNonceSequence sequence=HC_NONCE_SEQUENCE_INITIALIZER;
 if(!out||out->attempted||out->published||out->target.ready||!game||
    !((game->save.phase==HC_STOCK_REAPED_CLEAN&&!game->detected_no_sram)||(game->save.phase==HC_STOCK_REAPED_NO_SRAM&&game->detected_no_sram))||capture_matches(game,control,capture)||
    make_regions(game,game->token,out->clock,out->image,&names,regions)){errno=EINVAL;return -1;}
 int parent=game->save.target.parent;
 if(hc_binding_inventory(parent,game->binding,game->game,game->rom.sha256,game->token,game->epoch,regions,2,0,entries,16,&count)||
    count!=1||strcmp(entries[0].workspace,game->save.target.workspace_name)||entries[0].kind!=HCIV2_FINAL||!entries[0].workspace_present||
    !fstatat(parent,names.retained_file,&st,AT_SYMLINK_NOFOLLOW)||errno!=ENOENT){errno=EINVAL;return -1;}
 if(hc_nonce_sequence_init(&sequence))return -1;
 int result=hc_nonce_sequence_next(&sequence,nonce),saved=errno;if(hc_nonce_sequence_destroy(&sequence)&&!result){result=-1;saved=errno;}if(result){errno=saved;return -1;}
 char session[33],workspace[44];static const char hex[]="0123456789abcdef";memcpy(workspace,"checkpoint-",11);
 for(size_t i=0;i<16;i++){session[2*i]=hex[game->token[i]>>4];session[2*i+1]=hex[game->token[i]&15];workspace[11+2*i]=hex[nonce[i]>>4];workspace[12+2*i]=hex[nonce[i]&15];}session[32]=0;workspace[43]=0;
 if(!memcmp(nonce,game->token,16)||!strcmp(workspace,game->save.target.workspace_name)){errno=EINVAL;return -1;}
 out->attempted=1;out->game=game;out->capture=capture;out->epoch=game->epoch;memcpy(out->token,game->token,16);memcpy(out->binding,names.retained_binding,sizeof out->binding);
 if(hc_binding_create(parent,out->binding,game->game,game->rom.sha256,game->token,game->epoch,regions,3)||
    hciv2_create(parent,session,workspace,names.retained_file,HCIV2_FINAL)||
    hc_autosave_target_prepare(&out->target,parent,geteuid(),nonce,out->image,names.retained_file)||
    hc_autosave_target_write(&out->target,out->image,capture->image,capture->image_length)||verify_retained(out,game,capture,regions))return -2;
 out->published=1;return 0;
}
int hc_stock_retained_image_finish_save(HCStockRetainedImage *out,HCStockGameSession *game,HCStockControlSession *control,HCStockScreenshotReceipt *capture,const void *previous,size_t previous_length){
 HCSessionExpected regions[3];HCScreenshotSessionNames names;char clock[1024],image[1024];
 if(!out||!out->published||out->game!=game||out->capture!=capture||!game||out->epoch!=game->epoch||memcmp(out->token,game->token,16)||
    game->save.phase!=HC_STOCK_PUBLISHED||!game->save.published_bytes||game->save.published_length!=game->save.stage_size||
    !game->save.initial_valid||((previous==NULL)!=(previous_length==0))||!!previous!=!!game->save.initial_present||
    (previous&&(!game->save.initial_bytes||previous_length!=game->save.initial_length||memcmp(previous,game->save.initial_bytes,previous_length)))||
    capture_matches(game,control,capture)||make_regions(game,game->token,clock,image,&names,regions)||
    strcmp(out->clock,clock)||strcmp(out->image,image)||strcmp(out->binding,names.retained_binding)||verify_retained(out,game,capture,regions)){errno=EINVAL;return -1;}
 int r=hc_binding_finish_published(game->save.target.parent,out->binding,game->game,game->rom.sha256,game->token,game->epoch,regions,3,0,game->save.target.workspace_name,game->save.published_bytes,game->save.published_length,previous,previous_length);
 if(!r){game->finalized=1;if(verify_retained(out,game,capture,regions))return -2;}return r;
}
int hc_stock_retained_image_finish_no_sram(HCStockRetainedImage *out,HCStockGameSession *game,HCStockControlSession *control,HCStockScreenshotReceipt *capture,const void *previous,size_t previous_length){
 HCSessionExpected regions[3];HCScreenshotSessionNames names;char clock[1024],image[1024];
 if(!out||!out->published||out->game!=game||out->capture!=capture||!game||out->epoch!=game->epoch||memcmp(out->token,game->token,16)||
    !game->detected_no_sram||game->save.phase!=HC_STOCK_REAPED_NO_SRAM||!game->save.initial_valid||
    ((previous==NULL)!=(previous_length==0))||!!previous!=!!game->save.initial_present||
    (previous&&(!game->save.initial_bytes||previous_length!=game->save.initial_length||memcmp(previous,game->save.initial_bytes,previous_length)))||
    capture_matches(game,control,capture)||hc_stock_game_validate_no_sram(game)||make_regions(game,game->token,clock,image,&names,regions)||
    strcmp(out->clock,clock)||strcmp(out->image,image)||strcmp(out->binding,names.retained_binding)||verify_retained(out,game,capture,regions)){errno=EINVAL;return -1;}
 int r=hc_binding_finish_unpublished(game->save.target.parent,out->binding,game->game,game->rom.sha256,game->token,game->epoch,regions,3,0,game->save.target.workspace_name,previous,previous_length);
 if(r)return r;
 if(verify_retained(out,game,capture,regions)||hc_stock_save_close(&game->save)){game->fault=1;errno=EIO;return -2;}
 game->finalized=1;return 0;
}
int hc_stock_retained_image_recheck(HCStockRetainedImage *out,HCStockGameSession *game,HCStockControlSession *control,HCStockScreenshotReceipt *capture){
 HCSessionExpected regions[3];HCScreenshotSessionNames names;char clock[1024],image[1024];struct stat parent,locked;
 if(!out||!out->published||!out->target.ready||!out->target.consumed||out->game!=game||out->capture!=capture||!game||!game->finalized||!game->rom.ready||
    !control||control->save!=&game->save||control->exit_owner.save!=&game->save||!control->screenshot||control->screenshot->context!=capture||
    !capture||capture->game!=game||capture->phase!=3||capture->checkpoint.phase!=HC_CP_READY||capture->checkpoint.sequence!=1||!capture->reader.done||
    !capture->image||!capture->image_length||capture->image_length>8u*1024u*1024u||memcmp(capture->token,game->token,16)||memcmp(capture->checkpoint.session,game->token,16)||
    capture->epoch!=game->epoch||out->epoch!=game->epoch||memcmp(out->token,game->token,16)||memcmp(capture->game_code,game->game,sizeof game->game)||
    memcmp(capture->rom_digest,game->rom.sha256,sizeof capture->rom_digest)||game->save_lock<3||game->save.child.pid!=-1||game->save.child.input!=-1||
    fstat(out->target.parent,&parent)||fstat(game->save_lock,&locked)||!S_ISDIR(parent.st_mode)||parent.st_uid!=geteuid()||(parent.st_mode&0777)!=0700||
    parent.st_dev!=locked.st_dev||parent.st_ino!=locked.st_ino||hc_verified_launch_recheck(&game->rom)||hc_stock_control_refresh_finished(control)||
    hc_screenshot_png(capture->image,capture->image_length)||make_regions(game,game->token,clock,image,&names,regions)||
    strcmp(out->clock,clock)||strcmp(out->image,image)||strcmp(out->binding,names.retained_binding)||verify_retained(out,game,capture,regions)){errno=EINVAL;return -1;}
 return 0;
}
int hc_stock_retained_image_close(HCStockRetainedImage *out){
 if(!out||!out->attempted){errno=EINVAL;return -1;}
 if(out->target.ready&&hc_autosave_target_close(&out->target))return -1;
 out->published=0;return 0;
}
int hc_stock_retained_image_retire(HCStockRetainedImage *out,HCStockGameSession *game,HCStockControlSession *control,HCStockScreenshotReceipt *capture){
 HCSessionExpected regions[3];HCScreenshotSessionNames names;HCIV2Entry entries[16];size_t count=0;char clock[1024],image[1024];
 struct stat held,named,after;int fd=-1,ok=0;
 if(!out||out->retired||hc_stock_retained_image_recheck(out,game,control,capture)||
    make_regions(game,game->token,clock,image,&names,regions)){errno=EINVAL;return -1;}
 int result=hc_binding_finish_published(out->target.parent,out->binding,game->game,game->rom.sha256,game->token,game->epoch,
                                        regions,3,2,out->target.workspace_name,capture->image,capture->image_length,NULL,0);
 if(result)return result;
 /* The live retained PNG must still be exactly the verified capture after the
  * journal is retired; neither that image nor its binding is deleted. */
 fd=openat(out->target.parent,names.retained_file,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);
 if(fd>=0&&!fstat(fd,&held)&&!fstatat(out->target.parent,names.retained_file,&named,AT_SYMLINK_NOFOLLOW)&&
    held.st_dev==named.st_dev&&held.st_ino==named.st_ino&&
    !hc_verify_checkpoint_file(fd,geteuid(),capture->image,capture->image_length)&&
    !hc_binding_inventory(out->target.parent,out->binding,game->game,game->rom.sha256,game->token,game->epoch,regions,3,2,entries,16,&count)&&count==0&&
    !fstat(fd,&after)&&after.st_dev==held.st_dev&&after.st_ino==held.st_ino&&
    !fstatat(out->target.parent,names.retained_file,&named,AT_SYMLINK_NOFOLLOW)&&named.st_dev==held.st_dev&&named.st_ino==held.st_ino)ok=1;
 int saved=errno;if(fd>=0&&close(fd))ok=0;
 if(!ok){errno=saved?saved:EIO;return -2;}out->retired=1;return 0;
}
