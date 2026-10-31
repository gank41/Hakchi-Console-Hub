#define _POSIX_C_SOURCE 200809L
#include "checkpoint_receipt.h"
#include "control_pipe.h"
#include <assert.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#include <signal.h>
static const unsigned char valid[] = {137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,1,0,0,0,1,8,2,0,0,0,144,119,83,222,0,0,0,12,73,68,65,84,120,156,99,248,207,192,0,0,3,1,1,0,201,254,146,239,0,0,0,0,73,69,78,68,174,66,96,130};
static const uint8_t session[16]={1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16};
static void frame(uint8_t b[32],int kind) {memset(b,0,32);memcpy(b,"HKC1",4);memcpy(b+4,session,16);b[27]=9;b[28]=(uint8_t)kind;}
int main(void) {
 struct sigaction ignore={0};ignore.sa_handler=SIG_IGN;sigemptyset(&ignore.sa_mask);assert(sigaction(SIGPIPE,&ignore,NULL)==0);
 HCCheckpoint s; uint8_t b[32];
 uint8_t encoded[32], expected[32];frame(expected,1);
 assert(hc_checkpoint_encode(encoded,session,9,HC_CP_SAVE,1)==0);
 assert(memcmp(encoded,expected,32)==0);
 memset(encoded,0xaa,32);assert(hc_checkpoint_encode(encoded,session,9,HC_CP_SAVE,2)!=0);
 for(int i=0;i<32;i++)assert(encoded[i]==0xaa);
 assert(hc_checkpoint_encode(encoded,session,9,HC_CP_SAVE,0)==0 && encoded[29]==1);
 assert(hc_checkpoint_init(&s,session,9)==0 && hc_checkpoint_receipt(&s,encoded,32)!=0 && s.phase==HC_CP_FAILED);
 HCReceiptReader r=HC_RECEIPT_READER_INITIALIZER;
 int ack[2];assert(hc_control_pipe(ack)==0);
 assert(hc_checkpoint_send(ack[1],session,9,HC_CP_SAVE,1)==0);
 assert(hc_checkpoint_init(&s,session,9)==0);
 uint8_t fragment[5];int outcome=0;
 while(outcome==0){ssize_t n=read(ack[0],fragment,sizeof fragment);assert(n>0);outcome=hc_checkpoint_feed(&r,&s,fragment,(size_t)n);}
 assert(outcome==1 && s.phase==HC_CP_VERIFY_SAVE);close(ack[0]);
 assert(hc_checkpoint_send(ack[1],session,9,HC_CP_SAVE,1)!=0);close(ack[1]);
 r=(HCReceiptReader)HC_RECEIPT_READER_INITIALIZER;
 int fds[2];assert(pipe(fds)==0);pid_t child=fork();assert(child>=0);
 if(child==0){close(fds[0]);uint8_t packet[32];frame(packet,1);if(write(fds[1],packet,32)!=32)_exit(1);close(fds[1]);_exit(0);}
 close(fds[1]);assert(hc_checkpoint_init(&s,session,9)==0);uint8_t input[5];int result=0;
 while(result==0){ssize_t n=read(fds[0],input,sizeof input);assert(n>0);result=hc_checkpoint_feed(&r,&s,input,(size_t)n);assert(result>=0);}
 assert(result==1 && s.phase==HC_CP_VERIFY_SAVE);close(fds[0]);int status;assert(waitpid(child,&status,0)==child && WIFEXITED(status) && WEXITSTATUS(status)==0);
 r=(HCReceiptReader)HC_RECEIPT_READER_INITIALIZER;
 assert(hc_checkpoint_init(&s,session,9)==0);frame(b,1);
 assert(hc_checkpoint_feed(&r,&s,b,7)==0 && s.phase==HC_CP_WAIT_SAVE);
 assert(hc_checkpoint_feed(&r,&s,b+7,25)==1 && s.phase==HC_CP_VERIFY_SAVE);
 assert(hc_checkpoint_feed(&r,&s,b,1)!=0 && s.phase==HC_CP_FAILED);
 r=(HCReceiptReader)HC_RECEIPT_READER_INITIALIZER;
 assert(hc_checkpoint_init(&s,session,9)==0);frame(b,1);
 assert(hc_checkpoint_feed(&r,&s,b,33)!=0 && s.phase==HC_CP_FAILED);
 assert(hc_checkpoint_init(&s,session,9)==0 && s.phase==HC_CP_WAIT_SAVE);
 frame(b,1);assert(hc_checkpoint_receipt(&s,b,32)==0 && s.phase==HC_CP_VERIFY_SAVE);
 assert(hc_checkpoint_verified(&s,HC_CP_SAVE,1)==0 && s.phase==HC_CP_WAIT_IMAGE);
 frame(b,2);assert(hc_checkpoint_receipt(&s,b,32)==0 && s.phase==HC_CP_VERIFY_IMAGE);
 assert(hc_checkpoint_verify_image(&s,valid,sizeof valid,1)==0 && s.phase==HC_CP_READY);
 assert(hc_checkpoint_receipt(&s,b,32)!=0 && s.phase==HC_CP_FAILED);
 assert(hc_checkpoint_init(&s,session,9)==0);frame(b,1);assert(hc_checkpoint_receipt(&s,b,32)==0);
 assert(hc_checkpoint_verified(&s,HC_CP_SAVE,1)==0);frame(b,2);assert(hc_checkpoint_receipt(&s,b,32)==0);
 assert(hc_checkpoint_verified(&s,HC_CP_IMAGE,1)!=0 && s.phase==HC_CP_FAILED);
 assert(hc_checkpoint_init(&s,session,9)==0);frame(b,1);assert(hc_checkpoint_receipt(&s,b,32)==0);
 assert(hc_checkpoint_verified(&s,HC_CP_SAVE,1)==0);frame(b,2);assert(hc_checkpoint_receipt(&s,b,32)==0);
 assert(hc_checkpoint_verify_image(&s,valid,sizeof valid-1,1)!=0 && s.phase==HC_CP_FAILED);
 assert(hc_checkpoint_init(&s,session,9)==0);frame(b,2);
 assert(hc_checkpoint_receipt(&s,b,32)!=0 && s.phase==HC_CP_FAILED);
 assert(hc_checkpoint_init(&s,session,9)==0);frame(b,1);b[4]^=1;
 assert(hc_checkpoint_receipt(&s,b,32)!=0 && s.phase==HC_CP_FAILED);
 assert(hc_checkpoint_init(&s,session,9)==0);frame(b,1);b[27]=8;
 assert(hc_checkpoint_receipt(&s,b,32)!=0 && s.phase==HC_CP_FAILED);
 assert(hc_checkpoint_init(&s,session,9)==0);frame(b,1);b[29]=1;
 assert(hc_checkpoint_receipt(&s,b,32)!=0 && s.phase==HC_CP_FAILED);
 assert(hc_checkpoint_init(&s,session,9)==0);frame(b,1);b[31]=1;
 assert(hc_checkpoint_receipt(&s,b,32)!=0 && s.phase==HC_CP_FAILED);
 assert(hc_checkpoint_init(&s,session,9)==0);frame(b,1);
 assert(hc_checkpoint_receipt(&s,b,31)!=0 && s.phase==HC_CP_FAILED);
 assert(hc_checkpoint_init(&s,session,9)==0);frame(b,1);
 assert(hc_checkpoint_receipt(&s,b,32)==0);assert(hc_checkpoint_verified(&s,HC_CP_SAVE,0)!=0 && s.phase==HC_CP_FAILED);
 assert(hc_checkpoint_init(&s,session,9)==0);
 assert(hc_checkpoint_verified(&s,HC_CP_SAVE,1)!=0 && s.phase==HC_CP_FAILED);
 uint8_t empty[16]={0};assert(hc_checkpoint_init(&s,empty,9)!=0 && s.phase==HC_CP_INVALID);
 assert(hc_checkpoint_init(&s,session,0)!=0 && s.phase==HC_CP_INVALID);
 return 0;
}
