#include "arguments.h"
#include <stddef.h>
#include <stdio.h>
#include <string.h>
static const char *const names[HC_OPTION_COUNT]={
 "--title-code","--video-mode","--wait-transition-fd","--start-transition-fd","--finish-transition-fd",
 "--save-data-backing-file","--save-screenshot-on-quit","--rollback-output-dir","--rollback-mode","--save-on-quit",
 "--rollback-input-dir","--load-state-file","--load-time-path","--save-time-path","--decorative-frame-path"
};
static size_t length(const char *s){if(!s)return HC_ARGUMENT_BYTES;size_t n=0;while(n<HC_ARGUMENT_BYTES && s[n])n++;return n;}
static int game_code(const char *s){
 if(length(s)!=11 || memcmp(s,"CLV-U-",6))return 0;
 for(unsigned i=6;i<11;i++)if(!((s[i]>='A'&&s[i]<='Z')||(s[i]>='0'&&s[i]<='9')))return 0;
 return 1;
}
static int descriptor(const char *s){
 size_t n=length(s);if(!n || n>3 || (n>1 && s[0]=='0'))return -1;
 int value=0;for(size_t i=0;i<n;i++){if(s[i]<'0'||s[i]>'9')return -1;value=value*10+s[i]-'0';}
 return value>=3 && value<=255 ? value:-1;
}
static int normal_path(const char *s,char out[HC_ARGUMENT_BYTES]){
 if(!s || s[0]!='/' || length(s)>=HC_ARGUMENT_BYTES)return -1;
 size_t p=1,n=0;
 while(s[p]){
  while(s[p]=='/')p++;
  if(!s[p])break;
  size_t begin=p;
  while(s[p] && s[p]!='/'){
   unsigned char c=(unsigned char)s[p];
   if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='_'||c=='-'||c=='.'))return -1;
   p++;
  }
  size_t count=p-begin;
  if((count==1 && s[begin]=='.')||(count==2 && s[begin]=='.'&&s[begin+1]=='.') || n+count+1>=HC_ARGUMENT_BYTES)return -1;
  out[n++]='/';memcpy(out+n,s+begin,count);n+=count;
 }
 if(!n)return -1;
 out[n]=0;return 0;
}
static int starts(const char *s,const char *prefix){size_t n=strlen(prefix);return !strncmp(s,prefix,n) && s[n]!=0;}
int hc_launch_arguments(int argc,const char *const argv[],const char *code,HCLaunchArguments *output){
 if(!output || !argv || !game_code(code) || argc<8 || argc>HC_OPTION_COUNT*2 || argc%2)return -1;
 HCLaunchArguments result={0};char profile[128],cache[128];
 int n=snprintf(profile,sizeof profile,"/var/lib/clover/profiles/0/%s/",code);
 int m=snprintf(cache,sizeof cache,"/var/cache/clover/volatile/%s/",code);
 if(n<=0 || n>=(int)sizeof profile || m<=0 || m>=(int)sizeof cache)return -1;
 for(int i=0;i<argc;i+=2){
  const char *name=argv[i],*value=argv[i+1];size_t count=length(value);
  if(length(name)>=HC_ARGUMENT_BYTES || !count || count>=HC_ARGUMENT_BYTES)return -1;
  unsigned option=0;while(option<HC_OPTION_COUNT && strcmp(name,names[option]))option++;
  if(option==HC_OPTION_COUNT || (result.present&(1u<<option)))return -1;
  result.present|=1u<<option;
  if(option==HC_TITLE){if(strcmp(value,code))return -1;}
  else if(option==HC_VIDEO){if(strcmp(value,"pixel-perfect")&&strcmp(value,"keep-aspect-ratio")&&strcmp(value,"crt-filter"))return -1;}
  else if(option==HC_WAIT || option==HC_START || option==HC_FINISH){
   int fd=descriptor(value);if(fd<0)return -1;
   if(option==HC_WAIT)result.wait_fd=fd;else if(option==HC_START)result.start_fd=fd;else result.finish_fd=fd;
  }
  else if(option==HC_ROLLBACK_MODE){if(strcmp(value,"record"))return -1;}
  else {
   if(normal_path(value,result.values[option])!=0)return -1;
   const char *path=result.values[option];
   if(option==HC_FRAME){if(!starts(path,"/usr/share/backgrounds/"))return -1;}
   else if(option==HC_SRAM){if(!starts(path,profile))return -1;}
   else if(!starts(path,profile) && !starts(path,cache))return -1;
   continue;
  }
  memcpy(result.values[option],value,count+1);
 }
 unsigned required=(1u<<HC_TITLE)|(1u<<HC_WAIT)|(1u<<HC_START)|(1u<<HC_FINISH);
 if((result.present&required)!=required || result.wait_fd==result.start_fd || result.wait_fd==result.finish_fd || result.start_fd==result.finish_fd)return -1;
 if((result.present&(1u<<HC_LOAD)) && (result.present&(1u<<HC_ROLLBACK_IN)))return -1;
 if((result.present&(1u<<HC_SAVE)) && (result.present&(1u<<HC_ROLLBACK_OUT)))return -1;
 *output=result;return 0;
}

/* Match RetroArch path_init_savefile_rtc: replace only the final filename
 * extension, or append .rtc when there is none. Never alias SRAM and RTC. */
int hc_launch_save_paths(int argc,const char *const argv[],const char *code,HCGameSavePaths *output){
 HCLaunchArguments parsed;HCGameSavePaths paths={0};
 if(!output||hc_launch_arguments(argc,argv,code,&parsed)||!(parsed.present&(1u<<HC_SRAM)))return -1;
 const char *sram=parsed.values[HC_SRAM],*slash=strrchr(sram,'/');
 if(!slash||!slash[1]||slash[1]=='.')return -1;
 size_t n=strlen(sram);const char *dot=strrchr(slash+1,'.');size_t prefix=dot?(size_t)(dot-sram):n;
 if(n>=sizeof paths.sram||prefix+4>=sizeof paths.rtc)return -1;
 memcpy(paths.sram,sram,n+1);memcpy(paths.rtc,sram,prefix);memcpy(paths.rtc+prefix,".rtc",5);
 const unsigned char *a=(const unsigned char *)paths.sram,*b=(const unsigned char *)paths.rtc;
 for(;;a++,b++){unsigned char x=*a,y=*b;if(x>='A'&&x<='Z')x=(unsigned char)(x+32);if(y>='A'&&y<='Z')y=(unsigned char)(y+32);if(x!=y)break;if(!x)return -1;}
 *output=paths;return 0;
}

static int same_ascii_case(const char *a,const char *b){
 for(;;a++,b++){unsigned char x=(unsigned char)*a,y=(unsigned char)*b;if(x>='A'&&x<='Z')x=(unsigned char)(x+32);if(y>='A'&&y<='Z')y=(unsigned char)(y+32);if(x!=y)return 0;if(!x)return 1;}
}
int hc_launch_isolated_save_paths_at_root(int argc,const char *const argv[],const char *code,const char *sha,const char *root,HCGameSavePaths *output){
 HCGameSavePaths native,paths={0};char canonical[HC_ARGUMENT_BYTES];
 if(!output||!sha||length(sha)!=64||!root||normal_path(root,canonical)||strcmp(root,canonical)||!strcmp(root,"/")||hc_launch_save_paths(argc,argv,code,&native))return -1;
 for(size_t i=0;i<64;i++)if(!((sha[i]>='0'&&sha[i]<='9')||(sha[i]>='a'&&sha[i]<='f')))return -1;
 int a=snprintf(paths.sram,sizeof paths.sram,"%s/%s/hakchi/%s/%s/battery.srm",root,code,HC_COMPATIBILITY_ENGINE_ID,sha);
 int b=snprintf(paths.rtc,sizeof paths.rtc,"%s/%s/hakchi/%s/%s/battery.rtc",root,code,HC_COMPATIBILITY_ENGINE_ID,sha);
 if(a<=0||b<=0||(size_t)a>=sizeof paths.sram||(size_t)b>=sizeof paths.rtc||
    same_ascii_case(native.sram,paths.sram)||same_ascii_case(native.sram,paths.rtc)||
    same_ascii_case(native.rtc,paths.sram)||same_ascii_case(native.rtc,paths.rtc))return -1;
 *output=paths;return 0;
}
int hc_launch_isolated_save_paths(int argc,const char *const argv[],const char *code,const char *sha,HCGameSavePaths *output){
 return hc_launch_isolated_save_paths_at_root(argc,argv,code,sha,"/var/lib/clover/profiles/0",output);
}
/* The manager's screenshot name is independent of its save-state name.
 * A rollback directory uses its fixed "savestate" child, matching the manager
 * contract; these derived names remain untrusted until directories are pinned. */
static int manager_checkpoint(const HCLaunchArguments *args,HCManagerCheckpointPaths *out){
 HCManagerCheckpointPaths result={0};
 if(!args||!out)return -1;
 if(args->present&(1u<<HC_SAVE)){
  size_t n=length(args->values[HC_SAVE]);if(!n||n>=HC_ARGUMENT_BYTES)return -1;
  memcpy(result.save,args->values[HC_SAVE],n+1);result.have_save=1;
 }else if(args->present&(1u<<HC_ROLLBACK_OUT)){
  int n=snprintf(result.save,sizeof result.save,"%s/savestate",args->values[HC_ROLLBACK_OUT]);
  if(n<=0||n>=(int)sizeof result.save)return -1;result.have_save=1;
 }
 if(args->present&(1u<<HC_LOAD)){
  size_t n=length(args->values[HC_LOAD]);if(!n||n>=HC_ARGUMENT_BYTES)return -1;
  memcpy(result.load,args->values[HC_LOAD],n+1);result.have_load=1;
 }else if(args->present&(1u<<HC_ROLLBACK_IN)){
  int n=snprintf(result.load,sizeof result.load,"%s/savestate",args->values[HC_ROLLBACK_IN]);
  if(n<=0||n>=(int)sizeof result.load)return -1;result.have_load=1;
 }
 if(args->present&(1u<<HC_SCREENSHOT)){
  size_t n=length(args->values[HC_SCREENSHOT]);if(!n||n>=HC_ARGUMENT_BYTES)return -1;
  memcpy(result.image,args->values[HC_SCREENSHOT],n+1);result.have_image=1;
 }
 if(result.have_image&&((result.have_save&&same_ascii_case(result.save,result.image))||(result.have_load&&same_ascii_case(result.load,result.image))))return -1;
 *out=result;return 0;
}

/* Time files may be the same on load and save, but neither may alias game
 * SRAM/RTC or any requested state or screenshot. Names are not authorization. */
static int manager_time(const HCLaunchArguments *args,const HCGameSavePaths *native,const HCGameSavePaths *isolated,const HCManagerCheckpointPaths *checkpoint,HCManagerTimePaths *out){
 HCManagerTimePaths result={0};char rollback_state[HC_ARGUMENT_BYTES]={0};
 if(!args||!native||!isolated||!checkpoint||!out)return -1;
 if(args->present&(1u<<HC_LOAD_TIME)){strcpy(result.load,args->values[HC_LOAD_TIME]);result.have_load=1;}
 if(args->present&(1u<<HC_SAVE_TIME)){strcpy(result.save,args->values[HC_SAVE_TIME]);result.have_save=1;}
 if(!result.have_load&&!result.have_save){*out=result;return 0;}
 if(args->present&(1u<<HC_ROLLBACK_IN)){
  int n=snprintf(rollback_state,sizeof rollback_state,"%s/savestate",args->values[HC_ROLLBACK_IN]);
  if(n<=0||(size_t)n>=sizeof rollback_state)return -1;
 }
 const char *times[]={result.have_load?result.load:NULL,result.have_save?result.save:NULL};
 const char *other[]={native->sram,native->rtc,isolated->sram,isolated->rtc,
  checkpoint->have_save?checkpoint->save:NULL,checkpoint->have_image?checkpoint->image:NULL,checkpoint->have_load?checkpoint->load:NULL,
  (args->present&(1u<<HC_LOAD))?args->values[HC_LOAD]:NULL,
  (args->present&(1u<<HC_ROLLBACK_IN))?args->values[HC_ROLLBACK_IN]:NULL,
  (args->present&(1u<<HC_ROLLBACK_OUT))?args->values[HC_ROLLBACK_OUT]:NULL,
  rollback_state[0]?rollback_state:NULL};
 for(size_t i=0;i<2;i++)if(times[i])for(size_t j=0;j<sizeof other/sizeof other[0];j++)
  if(other[j]&&same_ascii_case(times[i],other[j]))return -1;
 *out=result;return 0;
}

int hc_parse_compatibility_menu_command(int argc,const char *const argv[],HCCompatibilityMenuCommand *output){
 static const char prefix[]="/var/lib/swifthakchi/snes-v2/objects/";
 HCCompatibilityMenuCommand result={0};HCGameSavePaths native={0};
 if(!output||!argv||argc<12||!argv[0]||!argv[2]||strcmp(argv[0],"--game")||strcmp(argv[2],"--rom")||!game_code(argv[1])||!argv[3])return -1;
 size_t prefix_len=sizeof prefix-1, n=length(argv[3]);
 if(n!=prefix_len+68||memcmp(argv[3],prefix,prefix_len))return -1;
 const char *name=argv[3]+prefix_len;
 for(size_t i=0;i<64;i++)if(!((name[i]>='0'&&name[i]<='9')||(name[i]>='a'&&name[i]<='f')))return -1;
 if(strcmp(name+64,".sfc")&&strcmp(name+64,".smc"))return -1;
 memcpy(result.game,argv[1],12);memcpy(result.rom_name,name,69);memcpy(result.digest,name,64);result.digest[64]=0;
 if(hc_launch_arguments(argc-4,argv+4,result.game,&result.manager)||
    hc_launch_save_paths(argc-4,argv+4,result.game,&native)||
    hc_launch_isolated_save_paths(argc-4,argv+4,result.game,result.digest,&result.saves)||
    manager_checkpoint(&result.manager,&result.checkpoint)||manager_time(&result.manager,&native,&result.saves,&result.checkpoint,&result.time))return -1;
 if(result.checkpoint.have_load&&(same_ascii_case(result.checkpoint.load,native.sram)||same_ascii_case(result.checkpoint.load,native.rtc)||
    same_ascii_case(result.checkpoint.load,result.saves.sram)||same_ascii_case(result.checkpoint.load,result.saves.rtc)))return -1;
 *output=result;return 0;
}
