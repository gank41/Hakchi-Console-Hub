#define _POSIX_C_SOURCE 200809L
#include "screenshot_completion.h"
#include "checkpoint_receipt.h"
#include "control_pipe.h"
#include <assert.h>
#include <stdbool.h>
#include <errno.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>
static const unsigned char valid[] = {137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,1,0,0,0,1,8,2,0,0,0,144,119,83,222,0,0,0,12,73,68,65,84,120,156,99,248,207,192,0,0,3,1,1,0,201,254,146,239,0,0,0,0,73,69,78,68,174,66,96,130};
static int success_marker,fail_marker;
bool hakchi_screenshot_completion_ok(const void *p){return p==&success_marker;}
static const uint8_t session[16]={1};
static void start_image(HCCheckpoint *c){assert(hc_checkpoint_init_image(c,session,7)==0);}
int main(void){struct sigaction ignore={0};ignore.sa_handler=SIG_IGN;sigemptyset(&ignore.sa_mask);assert(sigaction(SIGPIPE,&ignore,NULL)==0);
 int p[2];assert(hc_control_pipe(p)==0);HCScreenshotCompletion x;HCCheckpoint c;uint8_t frame[32];
 assert(hc_screenshot_completion_init(&x,p[1],session,7)==0);start_image(&c);
 hc_screenshot_completion_callback(&success_marker,&x,NULL);assert(x.attempted==1 && x.delivery==0);
 assert(read(p[0],frame,32)==32 && hc_checkpoint_receipt(&c,frame,32)==0);
 assert(hc_checkpoint_verify_image(&c,valid,sizeof valid,1)==0 && c.phase==HC_CP_READY);
 hc_screenshot_completion_callback(&success_marker,&x,NULL);assert(read(p[0],frame,32)==-1 && (errno==EAGAIN || errno==EWOULDBLOCK));
 assert(hc_screenshot_completion_init(&x,p[1],session,8)==0);
 hc_screenshot_completion_callback(&fail_marker,&x,NULL);assert(read(p[0],frame,32)==32 && frame[29]==1);
 assert(hc_screenshot_completion_init(&x,p[1],session,9)==0);close(p[0]);
 hc_screenshot_completion_callback(&success_marker,&x,NULL);assert(x.attempted==1 && x.delivery==-1);close(p[1]);return 0;}
