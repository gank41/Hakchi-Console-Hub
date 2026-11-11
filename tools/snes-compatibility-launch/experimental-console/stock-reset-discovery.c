#define _POSIX_C_SOURCE 200809L
#include "stock-reset-discovery.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#if defined(HC_TEST_INPUT_DISCOVERY) && defined(__arm__)
#error "Mock input discovery cannot be used on a console"
#endif
#ifdef HC_TEST_INPUT_DISCOVERY
#include "test-reset-discovery-shim.h"
#else
#include <linux/input.h>
#include <sys/ioctl.h>
#endif
/* Reject ambiguity. The caller still authenticates the model/key and trusted
 * /dev/input mount. Opening evdev does not grab or read any button input. */
int hc_stock_reset_discover(int directory,uid_t owner,const char *expected,uint16_t key){
 struct stat root,before,held,after;int selected=-1;char selected_name[16]={0};
 if(directory<3||!expected||!expected[0]||strnlen(expected,64)>=64||!key||key>767||fstat(directory,&root)||!S_ISDIR(root.st_mode)||root.st_uid!=owner||(root.st_mode&0022)){errno=EINVAL;return -1;}
 for(int i=0;i<32;i++){
  char name[16],device_name[64]={0};unsigned char keys[96]={0};
  if(snprintf(name,sizeof name,"event%d",i)<=0)goto fail;
  if(fstatat(directory,name,&before,AT_SYMLINK_NOFOLLOW)){if(errno==ENOENT)continue;goto fail;}
  if(!S_ISCHR(before.st_mode)||before.st_uid!=owner)goto fail;
  int fd=openat(directory,name,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(fd<0)goto fail;
  if(fstat(fd,&held)||!S_ISCHR(held.st_mode)||held.st_uid!=owner||held.st_dev!=before.st_dev||held.st_ino!=before.st_ino||held.st_rdev!=before.st_rdev){close(fd);goto fail;}
  int count=ioctl(fd,EVIOCGNAME(sizeof device_name),device_name);
  if(count<=0||count>(int)sizeof device_name||!memchr(device_name,0,(size_t)count)){close(fd);goto fail;}
  if(strcmp(device_name,expected)){if(close(fd))goto fail;continue;}
  count=ioctl(fd,EVIOCGBIT(EV_KEY,sizeof keys),keys);
  if(count<=key/8||count>(int)sizeof keys||!(keys[key/8]&(1u<<(key%8)))||selected>=0){close(fd);goto fail;}
  selected=fd;memcpy(selected_name,name,strlen(name)+1);
 }
 if(selected<0)goto fail;
 if(fstat(directory,&after)||after.st_dev!=root.st_dev||after.st_ino!=root.st_ino||after.st_uid!=owner||(after.st_mode&0022)||
    fstat(selected,&held)||fstatat(directory,selected_name,&after,AT_SYMLINK_NOFOLLOW)||!S_ISCHR(held.st_mode)||!S_ISCHR(after.st_mode)||held.st_uid!=owner||after.st_uid!=owner||held.st_dev!=after.st_dev||held.st_ino!=after.st_ino||held.st_rdev!=after.st_rdev)goto fail;
 return selected;
fail:
 if(selected>=0)close(selected);errno=EIO;return -1;
}
