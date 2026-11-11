#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
/* Host-only recovery of fixture data; this cannot authorize console writes. */
#ifdef __arm__
#error "Host-only recovery fixture"
#endif
#include "recovery-binding.h"
#include "recovery-observer.h"
#include "recovery-clock-wire.h"
#include "console-game.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
static int digit(char c){return c>='0'&&c<='9'?c-'0':c>='a'&&c<='f'?c-'a'+10:-1;}
int main(int argc,char **argv){
 if(argc!=5||argv[1][0]!='/'||strnlen(argv[2],12)!=11||strnlen(argv[3],65)!=64)return 2;
 int parent=open(argv[1],O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC),backup=open(argv[4],O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);
 if(parent<0||backup<0)return 2;
 struct stat st;if(fstat(backup,&st)||!S_ISREG(st.st_mode)||st.st_size<=0||st.st_size>131072)return 2;
 size_t length=(size_t)st.st_size;unsigned char *bytes=malloc(length);if(!bytes)return 2;
 for(size_t pos=0;pos<length;){ssize_t n=read(backup,bytes+pos,length-pos);if(n<0&&errno==EINTR)continue;if(n<=0)return 2;pos+=(size_t)n;}
 int scanfd=openat(parent,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(scanfd<0)return 2;
 DIR *scan=fdopendir(scanfd);if(!scan)return 2;char binding[41]={0};struct dirent *entry;unsigned count=0;
 size_t prefix=0;
 while((entry=readdir(scan))){size_t n=!strncmp(entry->d_name,"session_",8)?8:!strncmp(entry->d_name,"bind-",5)?5:0;if(!n)continue;if(strlen(entry->d_name)!=n+32||++count!=1)return 2;prefix=n;memcpy(binding,entry->d_name,n+33);}
 if(closedir(scan)||count!=1)return 2;
 unsigned char token[16];for(size_t i=0;i<16;i++){int a=digit(binding[prefix+2*i]),b=digit(binding[prefix+2*i+1]);if(a<0||b<0)return 2;token[i]=(unsigned char)((a<<4)|b);}
 char profiles[1024];if(strlen(argv[1])>=sizeof profiles)return 2;strcpy(profiles,argv[1]);
 for(int i=0;i<4;i++){char *slash=strrchr(profiles,'/');if(!slash||slash==profiles)return 2;*slash=0;}
 int profilesfd=open(profiles,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(profilesfd<0)return 2;
 HCLaunchRequest request={0};memcpy(request.game,argv[2],12);memcpy(request.digest,argv[3],65);memcpy(request.session,token,16);request.epoch=1;
 int sessiondir=openat(parent,"sessions",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(sessiondir<0)return 2;
 HCManagerRecordObservation inventory[2]={{0}};size_t found=0;
 if(hc_console_game_inventory_manager_records(sessiondir,request.game,request.digest,inventory,2,&found)||found!=1||inventory[0].status!=HC_MANAGER_RECORD_PRESENT||
    memcmp(inventory[0].request.session,request.session,16)||inventory[0].request.epoch!=request.epoch||inventory[0].paths.have_save||inventory[0].paths.have_image)return 2;
 if(close(sessiondir))return 2;
 HCRecoveryObservation observation;
 if(hc_recovery_observe_game(profilesfd,profiles,geteuid(),&request,0,&observation)){perror("app-facing recovery observation");return 3;}
 if(observation.entry_count!=1)return 2;
 HCIV2Entry records[16];size_t n=0;
 if(hciv2_inventory(parent,binding+prefix,records,16,&n)||n!=1||records[0].kind!=HCIV2_FINAL||!records[0].workspace_present||strcmp(records[0].region,"battery.srm"))return 2;
 HCRecoveryLiveSave *current=calloc(1,sizeof *current);if(!current)return 2;
 if(hc_recovery_read_current_game(profilesfd,profiles,geteuid(),&request,0,current)){perror("app-facing current save");return 4;}
 if(!current->present||current->length!=length)return 2;
 size_t frame_len=185+length+current->length;unsigned char *frame=calloc(1,frame_len);if(!frame)return 2;
 memcpy(frame,"HCRST30\0",8);if(hc_launch_request_encode(&request,frame+8))return 2;
 memcpy(frame+115,records[0].workspace,43);frame[158]=HC_RECOVERY_ORIGINAL_PRESENT;
 for(unsigned i=0;i<4;i++)frame[159+i]=(unsigned char)(length>>(8*i));
 memcpy(frame+163,bytes,length);size_t pos=163+length;frame[pos++]=1;
 for(unsigned i=0;i<4;i++)frame[pos+i]=(unsigned char)(current->length>>(8*i));pos+=4;
 memcpy(frame+pos,current->bytes,current->length);pos+=current->length;
 if(getenv("HC_FIXTURE_STALE_CURRENT"))frame[pos-current->length]^=1;
 for(unsigned i=0;i<8;i++){frame[pos+i]=(unsigned char)(observation.device>>(8*i));frame[pos+8+i]=(unsigned char)(observation.inode>>(8*i));}
 frame[pos+16]=(unsigned char)records[0].kind;
 int result=hc_battery_recovery_execute(profilesfd,profiles,geteuid(),frame,frame_len);
 free(frame);free(current);free(bytes);if(close(profilesfd)||close(backup)||close(parent))return 2;
 if(result)return 1;puts("HOST FIXTURE PREVIOUS SAVE RESTORED");return 0;
}
