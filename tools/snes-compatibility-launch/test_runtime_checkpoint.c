#define _POSIX_C_SOURCE 200809L
#include "runtime_checkpoint.h"
#include "checkpoint_receipt.h"
#include "control_pipe.h"
#include <assert.h>
#include <stdbool.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>
typedef void (*Callback)(void *,void *,const char *);
static Callback save_cb,image_cb;static void *save_ctx,*image_ctx;static bool allow_save=true,allow_image=true;static int marker;
bool hakchi_capture_game_state(const char *path,Callback cb,void *ctx){assert(!strcmp(path,"/safe/state"));save_cb=cb;save_ctx=ctx;return allow_save;}
bool hakchi_capture_game_state_fd(const char *path,int fd,Callback cb,void *ctx){assert(fd==42);return hakchi_capture_game_state(path,cb,ctx);}
bool take_screenshot_with_completion(const char *path,bool silence,bool framebuffer,Callback cb,void *ctx){assert(!strcmp(path,"/safe/state")&&silence&&framebuffer);image_cb=cb;image_ctx=ctx;return allow_image;}
bool hakchi_take_screenshot_fd(const char *path,int fd,bool valid,Callback cb,void *ctx){(void)fd;return take_screenshot_with_completion(path,true,valid,cb,ctx);}
bool video_driver_cached_frame_has_valid_framebuffer(void){return true;}
bool hakchi_save_completion_ok(const void *data,const char *error){return data==&marker && !error;}
bool hakchi_save_completion_matches(const void *data,const char *path){return data==&marker && !strcmp(path,"/safe/state");}
void hakchi_save_completion_dispose(void *p){(void)p;}
bool hakchi_screenshot_completion_ok(const void *data){return data==&marker;}
int main(void){struct sigaction ignore={0};ignore.sa_handler=SIG_IGN;sigemptyset(&ignore.sa_mask);assert(sigaction(SIGPIPE,&ignore,NULL)==0);
 int p[2];assert(hc_control_pipe(p)==0);const uint8_t session[16]={1};uint8_t frame[32];HCRuntimeCheckpoint c=HC_RUNTIME_CHECKPOINT_INITIALIZER;
 assert(hc_runtime_checkpoint_init(&c,p[1],session,12,"/safe/state")==0 && c.phase==HC_RT_READY);
 assert(hc_runtime_request_image(&c)!=0);assert(c.phase==HC_RT_FAILED);
 assert(hc_runtime_checkpoint_init(&c,p[1],session,12,"/safe/state")==0);
 assert(hc_runtime_request_save(&c)==0 && c.phase==HC_RT_SAVING);
 assert(hc_runtime_checkpoint_init(&c,p[1],session,99,"/safe/state")!=0 && c.phase==HC_RT_SAVING);
 save_cb(&marker,save_ctx,NULL);
 assert(c.phase==HC_RT_IMAGE_READY && read(p[0],frame,32)==32 && frame[28]==HC_CP_SAVE && frame[29]==0);
 assert(hc_runtime_request_image(&c)==0 && c.phase==HC_RT_IMAGING);image_cb(&marker,image_ctx,NULL);
 assert(c.phase==HC_RT_REPORTED && read(p[0],frame,32)==32 && frame[28]==HC_CP_IMAGE && frame[29]==0);
 assert(hc_runtime_checkpoint_init(&c,p[1],session,13,"/safe/state")==0);allow_save=false;
 assert(hc_runtime_request_save(&c)!=0 && c.phase==HC_RT_FAILED && read(p[0],frame,32)==32 && frame[29]==1);
 allow_save=true;assert(hc_runtime_checkpoint_init(&c,p[1],session,14,"/safe/state")==0);assert(hc_runtime_request_save(&c)==0);save_cb(&marker,save_ctx,NULL);assert(read(p[0],frame,32)==32);
 allow_image=false;assert(hc_runtime_request_image(&c)!=0 && c.phase==HC_RT_FAILED && read(p[0],frame,32)==32 && frame[29]==1);
 allow_image=true;assert(hc_runtime_checkpoint_init(&c,p[1],session,15,"/safe/state")==0);
 assert(hc_runtime_request_save_fd(&c,42)==0);save_cb(&marker,save_ctx,NULL);
 assert(read(p[0],frame,32)==32 && frame[29]==0 && c.phase==HC_RT_IMAGE_READY);
 assert(hc_runtime_request_image_fd(&c,43)==0);image_cb(&marker,image_ctx,NULL);
 assert(read(p[0],frame,32)==32 && frame[29]==0 && c.phase==HC_RT_REPORTED);
 close(p[0]);close(p[1]);return 0;}
