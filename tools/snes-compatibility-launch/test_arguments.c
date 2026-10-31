#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "arguments.h"
static const char *base[]={"--title-code","CLV-U-ABCDE","--video-mode","pixel-perfect","--wait-transition-fd","28","--start-transition-fd","31","--finish-transition-fd","33","--save-data-backing-file","/var/lib/clover/profiles/0/CLV-U-ABCDE/cartridge.sram","--rollback-mode","record","--rollback-output-dir","/var/cache/clover//volatile/CLV-U-ABCDE/suspendpoint0/rollback/","--save-screenshot-on-quit","/var/cache/clover//volatile/CLV-U-ABCDE/suspendpoint0/state.png","--save-time-path","/var/cache/clover//volatile/CLV-U-ABCDE/suspendpoint0/state.time"};
int main(void){
 HCLaunchArguments out,unchanged;memset(&unchanged,0xa5,sizeof unchanged);
 assert(hc_launch_arguments(20,base,"CLV-U-ABCDE",&out)==0);
 assert(out.wait_fd==28 && out.start_fd==31 && out.finish_fd==33);
 assert(!strcmp(out.values[HC_ROLLBACK_OUT],"/var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint0/rollback"));
 for(int fault=0;fault<16;fault++){
  const char *args[HC_OPTION_COUNT*2+2];memcpy(args,base,sizeof base);int count=20;const char *code="CLV-U-ABCDE";
  switch(fault){
   case 0:args[0]="--ra-extra";break;
   case 1:args[1]="CLV-U-XYZAB";break;
   case 2:args[5]="028";break;
   case 3:args[7]="28";break;
   case 4:args[9]="256";break;
   case 5:args[11]="/var/lib/clover/profiles/0/CLV-U-ABCDE/../other/save";break;
   case 6:args[11]="/var/lib/clover/profiles/0/CLV-U-ABCDE-other/save";break;
   case 7:args[11]="/var/lib/clover/profiles/0/CLV-P-ABCDE/save";break;
   case 8:args[17]="/tmp/state.png";break;
   case 9:args[20]="--video-mode";args[21]="crt-filter";count=22;break;
   case 10:count=19;break;
   case 11:args[3]="unsupported";break;
   case 12:args[13]="replay";break;
   case 13:code="CLV-U-ABCDE\n";break;
   case 14:args[17]="/var/cache/clover/volatile/CLV-U-ABCDE/$(bad).png";break;
   case 15:args[1]=NULL;break;
  }
  out=unchanged;assert(hc_launch_arguments(count,args,code,&out)!=0);assert(!memcmp(&out,&unchanged,sizeof out));
 }
 const char *load[]={"--title-code","CLV-U-ABCDE","--wait-transition-fd","28","--start-transition-fd","31","--finish-transition-fd","33","--load-state-file","/var/lib/clover/profiles/0/CLV-U-ABCDE/suspendpoint0/savestate","--rollback-input-dir","/var/lib/clover/profiles/0/CLV-U-ABCDE/suspendpoint1/rollback"};
 out=unchanged;assert(hc_launch_arguments(12,load,"CLV-U-ABCDE",&out)!=0);assert(!memcmp(&out,&unchanged,sizeof out));
 assert(hc_launch_arguments(8,load,"CLV-U-ABCDE",&out)==0);
 for(unsigned omitted=0;omitted<4;omitted++){
  const unsigned pairs[]={0,4,6,8};const char *args[20];unsigned at=0;
  for(unsigned i=0;i<20;i++)if(i!=pairs[omitted] && i!=pairs[omitted]+1)args[at++]=base[i];
  out=unchanged;assert(at==18);assert(hc_launch_arguments(18,args,"CLV-U-ABCDE",&out)!=0);assert(!memcmp(&out,&unchanged,sizeof out));
 }
 char huge[HC_ARGUMENT_BYTES+1];memset(huge,'A',sizeof huge-1);huge[sizeof huge-1]=0;
 for(unsigned fault=0;fault<5;fault++){
  const char *args[24];memcpy(args,base,sizeof base);int count=20;
  if(fault==0)args[0]=huge;
  if(fault==1)args[1]=huge;
  if(fault==2)args[3]="";
  if(fault==3)args[0]=NULL;
  if(fault==4){args[20]="--save-on-quit";args[21]="/var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint0/savestate";count=22;}
  out=unchanged;assert(hc_launch_arguments(count,args,"CLV-U-ABCDE",&out)!=0);assert(!memcmp(&out,&unchanged,sizeof out));
 }
 const char *art[22];memcpy(art,base,sizeof base);art[20]="--decorative-frame-path";art[21]="/usr/share/backgrounds/01";
 assert(hc_launch_arguments(22,art,"CLV-U-ABCDE",&out)==0);assert(!strcmp(out.values[HC_FRAME],"/usr/share/backgrounds/01"));
 out=unchanged;assert(hc_launch_arguments(20,NULL,"CLV-U-ABCDE",&out)!=0);assert(!memcmp(&out,&unchanged,sizeof out));
 assert(hc_launch_arguments(20,base,NULL,&out)!=0);assert(!memcmp(&out,&unchanged,sizeof out));
 assert(hc_launch_arguments(20,base,"CLV-U-ABCDE",NULL)!=0);
 HCGameSavePaths paths, prior;memset(&prior,0xa5,sizeof prior);paths=prior;
 assert(hc_launch_save_paths(20,base,"CLV-U-ABCDE",&paths)==0);
 assert(!strcmp(paths.sram,"/var/lib/clover/profiles/0/CLV-U-ABCDE/cartridge.sram"));
 assert(!strcmp(paths.rtc,"/var/lib/clover/profiles/0/CLV-U-ABCDE/cartridge.rtc"));
 const char *missing_sram[18];unsigned outindex=0;for(unsigned i=0;i<20;i++)if(i!=10&&i!=11)missing_sram[outindex++]=base[i];
 paths=prior;assert(hc_launch_save_paths(18,missing_sram,"CLV-U-ABCDE",&paths)<0&&!memcmp(&paths,&prior,sizeof paths));
 const char *variant[20];memcpy(variant,base,sizeof base);
 variant[11]="/var/lib/clover/profiles/0/CLV-U-ABCDE/cartridge.RTC";
 paths=prior;assert(hc_launch_save_paths(20,variant,"CLV-U-ABCDE",&paths)<0&&!memcmp(&paths,&prior,sizeof paths));
 variant[11]="/var/lib/clover/profiles/0/CLV-U-ABCDE/.hidden";
 paths=prior;assert(hc_launch_save_paths(20,variant,"CLV-U-ABCDE",&paths)<0&&!memcmp(&paths,&prior,sizeof paths));
 variant[11]="/var/lib/clover/profiles/0/CLV-U-ABCDE/noextension";
 assert(!hc_launch_save_paths(20,variant,"CLV-U-ABCDE",&paths));
 assert(!strcmp(paths.rtc,"/var/lib/clover/profiles/0/CLV-U-ABCDE/noextension.rtc"));
 paths=prior;assert(hc_launch_save_paths(20,base,"CLV-U-WRONG",&paths)<0&&!memcmp(&paths,&prior,sizeof paths));
 const char *rom="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
 assert(!hc_launch_isolated_save_paths(20,base,"CLV-U-ABCDE",rom,&paths));
 assert(!strcmp(paths.sram,"/var/lib/clover/profiles/0/CLV-U-ABCDE/hakchi/snes9x2010-fe690dd3-armhf-glibc223/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/battery.srm"));
 assert(!strcmp(paths.rtc,"/var/lib/clover/profiles/0/CLV-U-ABCDE/hakchi/snes9x2010-fe690dd3-armhf-glibc223/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/battery.rtc"));
 HCGameSavePaths first=paths;
 assert(!hc_launch_isolated_save_paths_at_root(20,base,"CLV-U-ABCDE",rom,"/tmp/hc-profile-root",&paths));
 assert(!strcmp(paths.sram,"/tmp/hc-profile-root/CLV-U-ABCDE/hakchi/snes9x2010-fe690dd3-armhf-glibc223/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/battery.srm"));
 const char *badroots[]={"relative","/tmp/../bad","/tmp//bad","/tmp/trailing/","/"};
 for(size_t i=0;i<sizeof badroots/sizeof badroots[0];i++){paths=prior;assert(hc_launch_isolated_save_paths_at_root(20,base,"CLV-U-ABCDE",rom,badroots[i],&paths)<0&&!memcmp(&paths,&prior,sizeof paths));}
 const char *other_rom="1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
 assert(!hc_launch_isolated_save_paths(20,base,"CLV-U-ABCDE",other_rom,&paths));
 assert(strcmp(first.sram,paths.sram)&&strcmp(first.rtc,paths.rtc));
 const char *native_collision[20];memcpy(native_collision,base,sizeof base);native_collision[11]=first.sram;
 paths=prior;assert(hc_launch_isolated_save_paths(20,native_collision,"CLV-U-ABCDE",rom,&paths)<0&&!memcmp(&paths,&prior,sizeof paths));
 paths=prior;assert(hc_launch_isolated_save_paths(20,base,"CLV-U-ABCDE","bad",&paths)<0&&!memcmp(&paths,&prior,sizeof paths));
 paths=prior;assert(hc_launch_isolated_save_paths(20,base,"CLV-U-WRONG",rom,&paths)<0&&!memcmp(&paths,&prior,sizeof paths));
 HCCompatibilityMenuCommand menu_out,menu_prior;memset(&menu_prior,0xa5,sizeof menu_prior);
 const char *menu[24]={"--game","CLV-U-ABCDE","--rom","/var/lib/swifthakchi/snes-v2/objects/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef.sfc"};
 memcpy(menu+4,base,sizeof base);
 assert(!hc_parse_compatibility_menu_command(24,menu,&menu_out));
 assert(!strcmp(menu_out.game,"CLV-U-ABCDE")&&!strcmp(menu_out.digest,rom));
 assert(!strcmp(menu_out.rom_name,"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef.sfc"));
 assert(!strcmp(menu_out.saves.sram,first.sram)&&menu_out.manager.wait_fd==28);
 assert(menu_out.checkpoint.have_save && menu_out.checkpoint.have_image);
 assert(!strcmp(menu_out.checkpoint.save,"/var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint0/rollback/savestate"));
 assert(!strcmp(menu_out.checkpoint.image,"/var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint0/state.png"));
 menu[18]="--save-on-quit";menu[19]="/var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint0/direct.state";
 assert(!hc_parse_compatibility_menu_command(24,menu,&menu_out));
 assert(!strcmp(menu_out.checkpoint.save,menu[19])&&!strcmp(menu_out.checkpoint.image,"/var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint0/state.png"));
 menu[21]=menu[19];menu_out=menu_prior;
 assert(hc_parse_compatibility_menu_command(24,menu,&menu_out)<0&&!memcmp(&menu_out,&menu_prior,sizeof menu_out));
 menu[18]=base[14];menu[19]=base[15];menu[21]=base[17];
 menu[3]="/var/lib/swifthakchi/snes-v2/objects/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef.smc";
 assert(!hc_parse_compatibility_menu_command(24,menu,&menu_out));
 menu[3]="/var/lib/swifthakchi/snes-v2/objects/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef.sfc";
 for(int fault=0;fault<8;fault++){
  const char *bad[24];memcpy(bad,menu,sizeof bad);int count=24;
  switch(fault){
   case 0:bad[1]="CLV-U-WRONG";break;
   case 1:bad[3]="/tmp/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef.sfc";break;
   case 2:bad[3]="/var/lib/swifthakchi/snes-v2/objects/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeF.sfc";break;
   case 3:bad[3]="/var/lib/swifthakchi/snes-v2/objects/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef.sfrom";break;
   case 4:bad[5]="CLV-U-WRONG";break;
   case 5:bad[14]="--unexpected";break;
   case 6:count=23;break;
   case 7:bad[2]=NULL;break;
  }
  menu_out=menu_prior;assert(hc_parse_compatibility_menu_command(count,bad,&menu_out)<0&&!memcmp(&menu_out,&menu_prior,sizeof menu_out));
 }
 puts("PASS: observed options, canonical owned-game paths, distinct descriptors, duplicate/unknown/missing/foreign/traversal/ambiguous-state refusal; output unchanged on failure");
 return 0;
}
