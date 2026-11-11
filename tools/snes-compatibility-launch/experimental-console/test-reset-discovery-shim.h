#include <sys/types.h>
#include <sys/stat.h>
#include <stdint.h>
#include <stddef.h>
int hc_test_fstat(int,struct stat *);
int hc_test_fstatat(int,const char *,struct stat *,int);
int hc_test_openat(int,const char *,int,...);
int hc_test_close(int);
int hc_test_ioctl(int,unsigned long,...);
#define fstat hc_test_fstat
#define fstatat hc_test_fstatat
#define openat hc_test_openat
#define close hc_test_close
#define ioctl hc_test_ioctl
#define HC_IOCTL_NAME 1
#define HC_IOCTL_KEYBITS 2
#define EVIOCGNAME(n) ((void)(n),HC_IOCTL_NAME)
#define EVIOCGBIT(t,n) ((void)(t),(void)(n),HC_IOCTL_KEYBITS)
#define EV_KEY 1
