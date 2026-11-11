#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#include "stock-config.h"
#include "mbedtls/sha256.h"
#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#if defined(HC_STOCK_TEST_TARGET_CONFIG) && !defined(__APPLE__)
#error "Host-only target configuration test cannot be used on a console"
#endif
#if !defined(__APPLE__) || defined(HC_STOCK_TEST_TARGET_CONFIG)
#ifdef HC_STOCK_TEST_TARGET_CONFIG
#ifndef HC_TEST_CONTROLLER_DIR
#error "Host-only target configuration test needs a private controller directory"
#endif
#define HC_CONTROLLER_DIRECTORY HC_TEST_CONTROLLER_DIR
#else
#define HC_CONTROLLER_DIRECTORY "/mnt/swifthakchi/snes-compat/autoconfig"
#endif
/* This is the unmodified mapping used during the successful SNES controller
 * trial. The installer must supply it at the fixed private location; neither
 * this hash nor a successful check enables launch. */
static int reviewed_controller(void){
 int dir=open(HC_CONTROLLER_DIRECTORY,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(dir<0)return -1;
 /* RetroArch scans all cfg files and may select a different match. Require a
  * private directory with exactly the reviewed mapping, not merely a correct
  * file alongside other unreviewed profiles. Caller excludes concurrent writes. */
 int duplicate=dup(dir);if(duplicate<0){close(dir);return -1;}
 if(fcntl(duplicate,F_SETFD,FD_CLOEXEC)){close(duplicate);close(dir);return -1;}
 DIR *listing=fdopendir(duplicate);if(!listing){close(duplicate);close(dir);return -1;}
 unsigned count=0;int invalid=0;struct dirent *item;errno=0;
 while((item=readdir(listing))){if(!strcmp(item->d_name,".")||!strcmp(item->d_name,".."))continue;count++;if(strcmp(item->d_name,"clovercon.cfg"))invalid=1;}
 if(errno)invalid=1;
 if(closedir(listing))invalid=1;
 if(invalid||count!=1){close(dir);errno=EINVAL;return -1;}
 HCVerifiedLaunch controller=HC_VERIFIED_LAUNCH_INITIALIZER;
 int result=hc_verified_rom_open(&controller,dir,"clovercon.cfg",geteuid(),"55018944a935bd04858d80f0f99d5a7ecfb61353565ba565eedd0075a55d2c35");
 if(!result&&hc_verified_launch_recheck(&controller))result=-1;
 if(controller.ready&&hc_verified_launch_close(&controller))result=-1;
 if(close(dir))result=-1;
 return result;
}
#endif
static int safe_path(const char *p){
 if(!p||p[0]!='/'||!p[1]||strnlen(p,1024)>=1024)return 0;size_t start=1;
 for(size_t i=1;;i++){unsigned char c=(unsigned char)p[i];if(!c||c=='/'){
  size_t n=i-start;if(!n||(n==1&&p[start]=='.')||(n==2&&p[start]=='.'&&p[start+1]=='.'))return 0;
  if(!c)return 1;start=i+1;continue;}
  if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='-'||c=='_'||c=='.'||c==' '))return 0;
 }
}
static int stage_matches(int stage,const char *path){
 struct stat dir,mapped;int opened;
 if(!safe_path(path)||fstat(stage,&dir)||!S_ISDIR(dir.st_mode)||dir.st_uid!=geteuid()||(dir.st_mode&0777)!=0700){errno=EINVAL;return -1;}
 opened=open(path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(opened<0)return -1;
 int match=!fstat(opened,&mapped)&&mapped.st_dev==dir.st_dev&&mapped.st_ino==dir.st_ino;
 if(close(opened)||!match){errno=EINVAL;return -1;}return 0;
}
static int screenshot_directory(int stage,struct stat *out){
 struct stat held,named;int fd=openat(stage,"shots",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return -1;
 int ok=!fstat(fd,&held)&&S_ISDIR(held.st_mode)&&held.st_uid==geteuid()&&(held.st_mode&0777)==0700&&
  !fstatat(stage,"shots",&named,AT_SYMLINK_NOFOLLOW)&&S_ISDIR(named.st_mode)&&named.st_dev==held.st_dev&&named.st_ino==held.st_ino&&named.st_mode==held.st_mode&&named.st_uid==held.st_uid;
 if(close(fd))ok=0;if(!ok){errno=EINVAL;return -1;}if(out)*out=held;return 0;
}
static int render_config(char *expected,size_t capacity,const char *path,int autoload,int screenshot){
 if(!expected||!capacity||!safe_path(path)||(autoload!=0&&autoload!=1)){errno=EINVAL;return -1;}
 int n;
#if defined(__APPLE__) && !defined(HC_STOCK_TEST_TARGET_CONFIG)
 const char *video="null",*audio="null",*input="null",*controller_settings="";
#else
 /* Drivers and mapping match the successful one-controller RAM trial. The
  * installer and live console behavior still need separate verification. */
 const char *video="gl",*audio="tinyalsa",*input="udev";
 const char *controller_settings="input_autodetect_enable = \"true\"\njoypad_autoconfig_dir = \"" HC_CONTROLLER_DIRECTORY "\"\nvideo_threaded = \"false\"\n";
 if(reviewed_controller())return -1;
#endif
 n=snprintf(expected,capacity,"video_driver = \"%s\"\naudio_driver = \"%s\"\ninput_driver = \"%s\"\n%smenu_driver = \"rgui\"\nconfig_save_on_exit = \"false\"\nsavestate_auto_save = \"false\"\nsavestate_auto_load = \"%s\"\nautosave_interval = \"0\"\nsavefile_directory = \"%s\"\nsavestate_directory = \"%s\"\nsavefiles_in_content_dir = \"false\"\nsavestates_in_content_dir = \"false\"\nsort_savefiles_enable = \"false\"\nsort_savestates_enable = \"false\"\n",video,audio,input,controller_settings,autoload?"true":"false",path,path);
 if(n<=0||(size_t)n>=capacity){errno=EINVAL;return -1;}
 if(screenshot){int more=snprintf(expected+n,capacity-(size_t)n,"stdin_cmd_enable = \"true\"\nvideo_gpu_screenshot = \"false\"\nscreenshots_in_content_dir = \"false\"\nscreenshot_directory = \"%s/shots\"\n",path);
  if(more<=0||(size_t)more>=capacity-(size_t)n){errno=EINVAL;return -1;}n+=more;}
 return n;
}
static int validate(HCVerifiedLaunch *config,int stage,const char *path,int autoload,int screenshot){
 struct stat dir,parent,shots,after;char expected[8192],actual[8192];size_t pos=0;
 if(!config||!config->ready||stage_matches(stage,path)||fstat(stage,&dir)||fstat(config->parent,&parent)||dir.st_dev!=parent.st_dev||dir.st_ino!=parent.st_ino||hc_verified_launch_recheck(config)){errno=EINVAL;return -1;}
 if(screenshot&&screenshot_directory(stage,&shots))return -1;
 int n=render_config(expected,sizeof expected,path,autoload,screenshot);

 if(n<0||config->snapshot.st_size!=(off_t)n){errno=EINVAL;return -1;}
 while(pos<(size_t)n){ssize_t got=pread(config->rom_fd,actual+pos,(size_t)n-pos,(off_t)pos);if(got<0&&errno==EINTR)continue;if(got<=0){errno=EIO;return -1;}pos+=(size_t)got;}
 if(memcmp(actual,expected,(size_t)n)||hc_verified_launch_recheck(config)||(screenshot&&(screenshot_directory(stage,&after)||shots.st_dev!=after.st_dev||shots.st_ino!=after.st_ino))){errno=EINVAL;return -1;}return 0;
}
int hc_stock_config_validate(HCVerifiedLaunch *config,int stage,const char *path,int autoload){return validate(config,stage,path,autoload,0);}
int hc_stock_config_validate_screenshot(HCVerifiedLaunch *config,int stage,const char *path,int autoload){return validate(config,stage,path,autoload,1);}
static int create(HCVerifiedLaunch *config,int stage,const char *path,int autoload,int screenshot){
 char contents[8192],digest[65];unsigned char bytes[32];static const char hex[]="0123456789abcdef";
 if(!config||config->ready||stage_matches(stage,path)||(screenshot&&screenshot_directory(stage,NULL))){errno=EINVAL;return -1;}
 int n=render_config(contents,sizeof contents,path,autoload,screenshot);if(n<0)return -1;
 if(mbedtls_sha256((const unsigned char *)contents,(size_t)n,bytes,0)){errno=EIO;return -1;}
 for(size_t i=0;i<32;i++){digest[i*2]=hex[bytes[i]>>4];digest[i*2+1]=hex[bytes[i]&15];}digest[64]=0;
 int fd=openat(stage,"retroarch.cfg",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0)return -1;
 int failed=0;size_t pos=0;
 while(pos<(size_t)n){ssize_t wrote=write(fd,contents+pos,(size_t)n-pos);if(wrote<0&&errno==EINTR)continue;if(wrote<=0){failed=1;break;}pos+=(size_t)wrote;}
 if(!failed&&fsync(fd))failed=1;if(close(fd))failed=1;
 if(!failed&&fsync(stage))failed=1;
 if(failed){errno=EIO;return -1;}
 if(stage_matches(stage,path)||hc_verified_rom_open(config,stage,"retroarch.cfg",geteuid(),digest))return -1;
 if(validate(config,stage,path,autoload,screenshot)){int saved=errno;(void)hc_verified_launch_close(config);errno=saved;return -1;}
 return 0;
}
int hc_stock_config_create(HCVerifiedLaunch *config,int stage,const char *path,int autoload){return create(config,stage,path,autoload,0);}
int hc_stock_config_create_screenshot(HCVerifiedLaunch *config,int stage,const char *path,int autoload){return create(config,stage,path,autoload,1);}
