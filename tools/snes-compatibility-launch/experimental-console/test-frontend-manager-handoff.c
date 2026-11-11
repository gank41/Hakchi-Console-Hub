#define _DARWIN_C_SOURCE 1
#include "frontend-main-entry.h"
#include "arguments.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

/* Bootstrap is simulated; the saved manager record and observer are real. */
int hc_frontend_bootstrap_receive_isolated(HCFrontendBootstrap *b,const HCFrontendIsolatedSpec *s,int input,unsigned timeout,const HCLaunchRequest *r){
 (void)s;(void)input;(void)timeout;b->ready=1;b->release_available=1;b->release_request=*r;return 0;
}
int hc_test_frontend_manager_handoff(const char *root,const char *profiles,const char *objects,const char *program,const char *sha,const HCLaunchRequest *request,const HCManagerCheckpointPaths *expected){
 char save[1024],rom[1024],hex[HC_LAUNCH_REQUEST_SIZE*2+1];unsigned char frame[HC_LAUNCH_REQUEST_SIZE];static const char digits[]="0123456789abcdef";
 assert(!hc_launch_request_encode(request,frame));for(size_t i=0;i<sizeof frame;i++){hex[2*i]=digits[frame[i]>>4];hex[2*i+1]=digits[frame[i]&15];}hex[sizeof frame*2]=0;
 assert(snprintf(save,sizeof save,"%s/%s/hakchi/%s/%s/battery.srm",profiles,request->game,HC_COMPATIBILITY_ENGINE_ID,request->digest)>0);
 assert(snprintf(rom,sizeof rom,"%s/%s.sfc",objects,request->digest)>0);
 char *args[]={(char *)program,"-s",save,"--hc-session-frame",hex,"-L",(char *)program,rom,NULL};int count=8;
 HCFrontendEntryConfig config={objects,profiles,11,205,203,204,206,1000,root,"child",sha,0};HCFrontendBootstrap boot=HC_FRONTEND_BOOTSTRAP_INITIALIZER;
 assert(!hc_frontend_entry_prepare(&boot,&count,args,&config)&&count==6);
 HCManagerCheckpointPaths actual={0};assert(!hc_frontend_entry_observe_manager(&boot,&config,&actual));
 assert(actual.have_save==expected->have_save&&actual.have_image==expected->have_image&&!strcmp(actual.save,expected->save)&&!strcmp(actual.image,expected->image));
 HCManagerTimePaths time={0},empty_time={0};actual=(HCManagerCheckpointPaths){0};
 assert(!hc_frontend_entry_observe_manager_full(&boot,&config,&actual,&time));
 assert(actual.have_save==expected->have_save&&actual.have_image==expected->have_image&&!strcmp(actual.save,expected->save)&&!strcmp(actual.image,expected->image)&&!memcmp(&time,&empty_time,sizeof time));
 HCFrontendBootstrap wrong=boot;wrong.release_request.session[0]^=1;HCManagerCheckpointPaths untouched={0};actual=untouched;
 assert(hc_frontend_entry_observe_manager(&wrong,&config,&actual)<0&&!memcmp(&actual,&untouched,sizeof actual));
 assert(hc_frontend_entry_observe_manager_full(&wrong,&config,&actual,&time)<0&&!memcmp(&actual,&untouched,sizeof actual)&&!memcmp(&time,&empty_time,sizeof time));
 return 0;
}
/* Uses the retained verified core from the handoff above and a real extended
 * session record created by the host entry fixture. */
int hc_test_frontend_manager_time_handoff(const char *profiles,const HCLaunchRequest *request,const HCManagerCheckpointPaths *expected,const HCManagerTimePaths *expected_time){
 HCFrontendEntryConfig cfg={0};cfg.profiles_root=profiles;HCFrontendBootstrap boot=HC_FRONTEND_BOOTSTRAP_INITIALIZER;
 boot.ready=1;boot.release_available=1;boot.release_request=*request;
 HCManagerCheckpointPaths paths={0},empty_paths={0};HCManagerTimePaths time={0},empty_time={0};
 assert(!hc_frontend_entry_observe_manager_full(&boot,&cfg,&paths,&time));
 assert(paths.have_save==expected->have_save&&paths.have_image==expected->have_image&&!strcmp(paths.save,expected->save)&&!strcmp(paths.image,expected->image));
 assert(time.have_load==expected_time->have_load&&time.have_save==expected_time->have_save&&!strcmp(time.load,expected_time->load)&&!strcmp(time.save,expected_time->save));
 paths=empty_paths;time=empty_time;assert(hc_frontend_entry_observe_manager(&boot,&cfg,&paths)<0&&!memcmp(&paths,&empty_paths,sizeof paths));
 boot.release_request.epoch++;assert(hc_frontend_entry_observe_manager_full(&boot,&cfg,&paths,&time)<0&&!memcmp(&paths,&empty_paths,sizeof paths)&&!memcmp(&time,&empty_time,sizeof time));
 return 0;
}
