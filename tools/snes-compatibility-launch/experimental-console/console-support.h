#ifndef HC_CONSOLE_SUPPORT_H
#define HC_CONSOLE_SUPPORT_H
#include "verified-launch.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* The holder must exclude directory mutation and descriptor-table races until
 * every child is reaped. Rechecks detect replacement, but do not themselves
 * prevent it, authenticate a console, or authorize execution. */
typedef struct HCConsoleSupport {
 int root, autoconfig, ready;
 const void *borrower;
 struct stat root_stat, auto_stat;
 char path[1024];
 HCVerifiedLaunch files[4];
} HCConsoleSupport;
#define HC_CONSOLE_SUPPORT_INITIALIZER { .root=-1, .autoconfig=-1 }

static inline int hc_console_support_single_controller(int dir){
 int fd=openat(dir,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
 if(fd<0)return -1;
 DIR *listing=fdopendir(fd);if(!listing){close(fd);return -1;}
 int count=0,bad=0;struct dirent *entry;errno=0;
 while((entry=readdir(listing))){
  if(!strcmp(entry->d_name,".")||!strcmp(entry->d_name,".."))continue;
  ++count;if(strcmp(entry->d_name,"clovercon.cfg"))bad=1;
 }
 if(errno)bad=1;
 if(closedir(listing))bad=1;
 if(bad||count!=1){errno=EINVAL;return -1;}
 return 0;
}
static inline int hc_console_support_recheck(HCConsoleSupport *s){
 struct stat root,dir,located,path_stat;
 if(!s||!s->ready)return -1;
 int path_fd=open(s->path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
 if(path_fd<0)return -1;
 int path_bad=fstat(path_fd,&path_stat);
 if(close(path_fd))path_bad=1;
 if(path_bad||path_stat.st_dev!=s->root_stat.st_dev||path_stat.st_ino!=s->root_stat.st_ino||fstat(s->root,&root)||fstat(s->autoconfig,&dir)||
    root.st_dev!=s->root_stat.st_dev||root.st_ino!=s->root_stat.st_ino||root.st_uid!=s->root_stat.st_uid||root.st_mode!=s->root_stat.st_mode||
    dir.st_dev!=s->auto_stat.st_dev||dir.st_ino!=s->auto_stat.st_ino||dir.st_uid!=s->auto_stat.st_uid||dir.st_mode!=s->auto_stat.st_mode||
    fstatat(s->root,"autoconfig",&located,AT_SYMLINK_NOFOLLOW)||!S_ISDIR(located.st_mode)||
    dir.st_dev!=located.st_dev||dir.st_ino!=located.st_ino||dir.st_uid!=located.st_uid||dir.st_mode!=located.st_mode||
    hc_console_support_single_controller(s->autoconfig))return -1;
 for(size_t i=0;i<4;i++)if(hc_verified_launch_recheck(&s->files[i]))return -1;
 return 0;
}
/* The target runner must use the exact held frontend and core at the fixed
 * runtime paths. This is a check, not exclusive ownership or a launch grant. */
static inline int hc_console_support_matches_launch(HCConsoleSupport *s,HCVerifiedLaunch *frontend,const char *frontend_path,HCVerifiedLaunch *core,const char *core_path){
 if(!s||!frontend_path||!core_path||frontend!=&s->files[0]||core!=&s->files[1]){errno=EINVAL;return -1;}
#if defined(__arm__)
 if(strcmp(s->path,"/mnt/swifthakchi/snes-compat")){errno=EINVAL;return -1;}
#endif
 char expected_frontend[1100],expected_core[1100];
 int a=snprintf(expected_frontend,sizeof expected_frontend,"%s/retroarch",s->path);
 int b=snprintf(expected_core,sizeof expected_core,"%s/snes9x2010_libretro.so",s->path);
 if(a<0||b<0||(size_t)a>=sizeof expected_frontend||(size_t)b>=sizeof expected_core||
    strcmp(frontend_path,expected_frontend)||strcmp(core_path,expected_core)){errno=EINVAL;return -1;}
 return hc_console_support_recheck(s);
}
/* Caller excludes descriptor-table reuse while closing, including retries. */
static inline int hc_console_support_close_fd(int *slot){
 if(*slot<0)return 0;
 int fd=*slot;*slot=-1;
 if(!close(fd))return 0;
 int saved=errno;errno=0;
 if(fcntl(fd,F_GETFD)!=-1||errno!=EBADF)*slot=fd;
 errno=saved?saved:EIO;return -1;
}
/* Caller must stop users of the borrowed descriptors before close. A failure
 * leaves remaining descriptors in the holder, which must not be reused. */
static inline int hc_console_support_close(HCConsoleSupport *s){
 if(!s){errno=EINVAL;return -1;}
 if(s->borrower){errno=EBUSY;return -1;}
 int bad=0;s->ready=0;
 for(size_t i=0;i<4;i++)if(s->files[i].ready&&hc_verified_launch_close(&s->files[i]))bad=1;
 if(bad)return -1;
 if(hc_console_support_close_fd(&s->autoconfig))return -1;
 if(hc_console_support_close_fd(&s->root))return -1;
 return 0;
}
static inline int hc_console_support_open(HCConsoleSupport *s,const char *path,uid_t owner){
 static const char *names[]={"retroarch","snes9x2010_libretro.so","size-probe","clovercon.cfg"};
 static const char *hashes[]={"2aa763b0ccd4a783bcb88bdd8e012e38cd8b60c2d5ece7f4db847a71d941f972","ea4fab232ce2479c61099240d20196172051027fb7f55a9eabf2c5d9c4342286","fa7240e655e7592d08ee87fdf68b25e5e0a9f3046f9e3192ce63d9ef68d7993e","55018944a935bd04858d80f0f99d5a7ecfb61353565ba565eedd0075a55d2c35"};
 if(!s||!path||s->ready||s->borrower||s->root!=-1||s->autoconfig!=-1||strnlen(path,sizeof s->path)>=sizeof s->path){errno=EINVAL;return -1;}
 strcpy(s->path,path);
 s->root=open(path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
 if(s->root<0||fstat(s->root,&s->root_stat)||!S_ISDIR(s->root_stat.st_mode)||s->root_stat.st_uid!=owner||(s->root_stat.st_mode&0022))goto fail;
 s->autoconfig=openat(s->root,"autoconfig",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
 if(s->autoconfig<0||fstat(s->autoconfig,&s->auto_stat)||!S_ISDIR(s->auto_stat.st_mode)||s->auto_stat.st_uid!=owner||(s->auto_stat.st_mode&0022))goto fail;
 for(size_t i=0;i<4;i++){
  if(hc_verified_rom_open(&s->files[i],i==3?s->autoconfig:s->root,names[i],owner,hashes[i]))goto fail;
  if((i==0||i==2)&&!(s->files[i].snapshot.st_mode&S_IXUSR))goto fail;
 }
 s->ready=1;if(hc_console_support_recheck(s))goto fail;
 return 0;
fail:
 {int saved=errno;if(hc_console_support_close(s))return -1;errno=saved;return -1;}
}
#endif
