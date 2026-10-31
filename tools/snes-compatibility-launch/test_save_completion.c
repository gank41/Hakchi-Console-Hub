#define _POSIX_C_SOURCE 200809L
#include "save_completion.h"
#include "checkpoint_receipt.h"
#include "control_pipe.h"
#include <assert.h>
#include <stdbool.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>
typedef struct {const char *path;bool ok;} FakeSave;
bool hakchi_save_completion_ok(const void *p,const char *error){const FakeSave *s=p;return s && !error && s->ok;}
bool hakchi_save_completion_matches(const void *p,const char *expected){const FakeSave *s=p;return s && expected && !strcmp(s->path,expected);}
void hakchi_save_completion_dispose(void *p){(void)p;}
int main(void){struct sigaction ignore={0};ignore.sa_handler=SIG_IGN;sigemptyset(&ignore.sa_mask);assert(sigaction(SIGPIPE,&ignore,NULL)==0);
 int pipefd[2];assert(hc_control_pipe(pipefd)==0);const uint8_t session[16]={3};HCSaveCompletion c;uint8_t frame[32];FakeSave save={"/private/state",true};
 assert(hc_save_completion_init(&c,pipefd[1],session,42,"/private/state")==0);
 hc_save_completion_callback(&save,&c,NULL);assert(c.attempted==1 && c.delivery==0);assert(read(pipefd[0],frame,32)==32 && frame[28]==HC_CP_SAVE && frame[29]==0);
 assert(hc_save_completion_init(&c,pipefd[1],session,43,"/other/state")==0);
 hc_save_completion_callback(&save,&c,NULL);assert(read(pipefd[0],frame,32)==32 && frame[29]==1);
 assert(hc_save_completion_init(&c,pipefd[1],session,44,"/private/state")==0);
 hc_save_completion_callback(&save,&c,"failed");assert(read(pipefd[0],frame,32)==32 && frame[29]==1);
 assert(hc_save_completion_init(&c,pipefd[1],session,45,"relative")==-1);
 close(pipefd[0]);close(pipefd[1]);return 0;}
