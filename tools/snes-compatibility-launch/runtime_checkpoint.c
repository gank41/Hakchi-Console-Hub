#include "runtime_checkpoint.h"
#include <stdbool.h>
#include <string.h>
typedef void (*HCCompletionCallback)(void *,void *,const char *);
extern bool hakchi_capture_game_state(const char *,HCCompletionCallback,void *);
extern bool hakchi_capture_game_state_fd(const char *,int,HCCompletionCallback,void *);
extern bool take_screenshot_with_completion(const char *,bool,bool,HCCompletionCallback,void *);
extern bool hakchi_take_screenshot_fd(const char *,int,bool,HCCompletionCallback,void *);
extern bool video_driver_cached_frame_has_valid_framebuffer(void);
static int fail(HCRuntimeCheckpoint *c) {if(c)c->phase=HC_RT_FAILED;return -1;}
int hc_runtime_checkpoint_init(HCRuntimeCheckpoint *c,int fd,const uint8_t session[16],uint64_t sequence,const char *path) {
 if(!c || c->outstanding || (c->phase!=HC_RT_INVALID && c->phase!=HC_RT_REPORTED && c->phase!=HC_RT_FAILED)) return -1;
 HCRuntimeCheckpoint next;memset(&next,0,sizeof next);
 if(hc_save_completion_init(&next.save,fd,session,sequence,path)!=0 ||
    hc_screenshot_completion_init(&next.image,fd,session,sequence)!=0) {memset(c,0,sizeof *c);return -1;}
 next.phase=HC_RT_READY;*c=next;return 0;
}
static void save_done(void *data,void *context,const char *error) {
 HCRuntimeCheckpoint *c=context;
 if(!c) {hc_save_completion_callback(data,NULL,"missing context");return;}
 hc_save_completion_callback(data,&c->save,c->phase==HC_RT_SAVING?error:"unexpected completion");
 c->outstanding=0;
 c->phase=c->phase==HC_RT_SAVING && c->save.reported_success==1 && c->save.delivery==0 ? HC_RT_IMAGE_READY:HC_RT_FAILED;
}
static void image_done(void *data,void *context,const char *error) {
 HCRuntimeCheckpoint *c=context;if(!c)return;
 hc_screenshot_completion_callback(data,&c->image,c->phase==HC_RT_IMAGING?error:"unexpected completion");
 c->outstanding=0;
 c->phase=c->phase==HC_RT_IMAGING && c->image.reported_success==1 && c->image.delivery==0 ? HC_RT_REPORTED:HC_RT_FAILED;
}
int hc_runtime_request_save(HCRuntimeCheckpoint *c) {
 if(!c || c->phase!=HC_RT_READY)return fail(c);
 c->phase=HC_RT_SAVING;c->outstanding=1;
 if(!hakchi_capture_game_state(c->save.expected,save_done,c)) {
    c->outstanding=0;hc_save_completion_callback(NULL,&c->save,"save not queued");return fail(c);
 }
 return 0;
}
int hc_runtime_request_save_fd(HCRuntimeCheckpoint *c,int fd) {
 if(!c || c->phase!=HC_RT_READY || fd<0)return fail(c);
 c->phase=HC_RT_SAVING;c->outstanding=1;
 if(!hakchi_capture_game_state_fd(c->save.expected,fd,save_done,c)) {
    c->outstanding=0;hc_save_completion_callback(NULL,&c->save,"save not queued");return fail(c);
 }
 return 0;
}
int hc_runtime_request_image(HCRuntimeCheckpoint *c) {
 if(!c || c->phase!=HC_RT_IMAGE_READY)return fail(c);
 c->phase=HC_RT_IMAGING;c->outstanding=1;
 if(!take_screenshot_with_completion(c->save.expected,true,video_driver_cached_frame_has_valid_framebuffer(),image_done,c)) {
    c->outstanding=0;hc_screenshot_completion_callback(NULL,&c->image,"screenshot not queued");return fail(c);
 }
 return 0;
}
int hc_runtime_request_image_fd(HCRuntimeCheckpoint *c,int fd) {
 if(!c || c->phase!=HC_RT_IMAGE_READY || fd<0)return fail(c);
 c->phase=HC_RT_IMAGING;c->outstanding=1;
 if(!hakchi_take_screenshot_fd(c->save.expected,fd,video_driver_cached_frame_has_valid_framebuffer(),image_done,c)) {
    c->outstanding=0;hc_screenshot_completion_callback(NULL,&c->image,"screenshot not queued");return fail(c);
 }
 return 0;
}
