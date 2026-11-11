#define _DARWIN_C_SOURCE 1
#include "test-reset-discovery-shim.h"
#undef fstat
#undef fstatat
#undef openat
#undef close
#undef ioctl
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
static int mode,base_fd=20;
void hc_test_device_fd_base(int value){base_fd=value;}
void hc_test_devices(int scenario){mode=scenario;}
static int index_for(const char *path){int i=-1;char rest;return sscanf(path,"event%d%c",&i,&rest)==1?i:-1;}
int hc_test_fstat(int fd,struct stat *s){memset(s,0,sizeof *s);if(fd==10){s->st_mode=S_IFDIR|0755;s->st_uid=0;return 0;}if(fd>=base_fd&&fd<=base_fd+31){int i=fd-base_fd;s->st_mode=S_IFCHR|0600;s->st_uid=0;s->st_dev=1;s->st_ino=(ino_t)(100+i);s->st_rdev=(dev_t)(200+i);return 0;}errno=EBADF;return -1;}
int hc_test_fstatat(int d,const char *name,struct stat *s,int flags){(void)flags;int i=index_for(name);if(d!=10||i<0||(i!=(mode==10?7:3)&&!(mode==1&&i==4)&&!(mode==11&&i==2))){errno=ENOENT;return -1;}int r=hc_test_fstat(base_fd+i,s);if(mode==5)s->st_mode=S_IFLNK|0777;if(mode==6)s->st_uid=1;if(mode==7&&i==3){static int seen;if(++seen%2==0)s->st_ino++;}return r;}
int hc_test_openat(int d,const char *name,int flags,...){(void)flags;int i=index_for(name);if(d!=10||i<0||(i!=(mode==10?7:3)&&!(mode==1&&i==4)&&!(mode==11&&i==2))){errno=ENOENT;return -1;}if(mode==3){errno=EACCES;return -1;}return base_fd+i;}
int hc_test_close(int fd){(void)fd;return 0;}
int hc_test_ioctl(int fd,unsigned long request,...){va_list a;va_start(a,request);void *data=va_arg(a,void *);va_end(a);if(request==HC_IOCTL_NAME){if(mode==8){memset(data,'X',64);return 64;}const char *n=mode==2?"other-device":mode==11&&fd==base_fd+2?"sunxi-knob":"sunxi-keyboard";strcpy(data,n);return (int)strlen(n)+1;}if(request==HC_IOCTL_KEYBITS){if(mode==9)return 1;memset(data,0,96);int key=mode==11&&fd==base_fd+2?116:115;if(mode!=4)((unsigned char *)data)[key/8]|=1u<<(key%8);return 96;}errno=EINVAL;return -1;}
