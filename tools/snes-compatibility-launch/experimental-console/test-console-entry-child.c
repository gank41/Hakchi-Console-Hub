#define _POSIX_C_SOURCE 200809L
#include "launch-request.h"
#include "startup-status.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc,char **argv){
 const char *image=getenv("HC_EXPECT_IMAGE");
 const char *save=getenv("HC_EXPECT_SAVE");
 if(image){assert(!strcmp(argv[5],"--hc-manager-screenshot")&&!strcmp(argv[6],image));
  if(save)assert(argc==12&&!strcmp(argv[7],"--hc-manager-save")&&!strcmp(argv[8],save)&&!strcmp(argv[9],"-L"));
  else assert(argc==10&&!strcmp(argv[7],"-L"));}
 HCLaunchRequest request={0};char rom[3];
 assert(!hc_launch_request_receive(0,3000,&request));assert(pread(205,rom,3,0)==3&&rom[0]=='a'&&rom[1]=='b'&&rom[2]=='c');
 assert(!hc_startup_send(203,request.session,request.epoch,HC_STARTUP_OK));assert(!close(203));
 assert(!hc_startup_send(206,request.session,request.epoch,HC_STARTUP_OK));assert(!close(206));
 for(;;)pause();
}
