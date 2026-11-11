#define _GNU_SOURCE 1
#define _DARWIN_C_SOURCE 1
#include "nonce-sequence.h"
#if defined(__arm__) && (defined(HC_NONCE_TEST_LEGACY) || defined(HC_NONCE_TEST_INJECT))
#error "Test entropy must never be built for ARM"
#endif
#include <errno.h>
#include <string.h>
#include <unistd.h>
#if defined(__APPLE__) && !defined(HC_NONCE_TEST_INJECT) && !defined(HC_NONCE_TEST_LEGACY)
#include <sys/random.h>
#endif
#if (defined(__linux__) || defined(HC_NONCE_TEST_LEGACY)) && !defined(HC_NONCE_TEST_INJECT)
#include <fcntl.h>
#include <sys/stat.h>
#if defined(__linux__)
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#endif
#ifdef HC_NONCE_TEST_LEGACY
extern long hc_test_kernel_random(void *,size_t,unsigned);
extern int hc_test_kernel_open(const char *,int);
extern int hc_test_kernel_fstat(int,struct stat *);
extern ssize_t hc_test_kernel_read(int,void *,size_t);
extern int hc_test_kernel_close(int);
#define random_open hc_test_kernel_open
#define random_fstat hc_test_kernel_fstat
#define random_read hc_test_kernel_read
#define random_close hc_test_kernel_close
#else
#define random_open open
#define random_fstat fstat
#define random_read read
#define random_close close
#endif
/* Old kernels lack getrandom. Never silently use a predictable identifier or
 * wait indefinitely for entropy. Verify the standard random character device;
 * an empty pool, unexpected device, read or close failure is a startup error. */
static int legacy_entropy(uint8_t out[12]){
 uint8_t bytes[12];size_t off=0;struct stat st;
 int fd=random_open("/dev/random",O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return -1;
 int saved=0;
 if(random_fstat(fd,&st)||!S_ISCHR(st.st_mode)||major(st.st_rdev)!=1||minor(st.st_rdev)!=8){saved=EIO;goto done;}
 while(off<sizeof bytes){ssize_t n=random_read(fd,bytes+off,sizeof bytes-off);if(n<0&&errno==EINTR)continue;if(n<=0||(size_t)n>sizeof bytes-off){saved=n<0?errno:EIO;goto done;}off+=(size_t)n;}
done:
 if(random_close(fd)&&!saved)saved=errno?errno:EIO;
 if(saved){errno=saved;return -1;}memcpy(out,bytes,sizeof bytes);return 0;
}
#endif
static int entropy(uint8_t out[12]){
#ifdef HC_NONCE_TEST_INJECT
 extern int hc_test_nonce_entropy(uint8_t [12]);return hc_test_nonce_entropy(out);
#elif defined(HC_NONCE_TEST_LEGACY) || (defined(__linux__) && defined(SYS_getrandom))
 size_t off=0;while(off<12){
#ifdef HC_NONCE_TEST_LEGACY
  long n=hc_test_kernel_random(out+off,12-off,1u);
#else
  long n=syscall(SYS_getrandom,out+off,12-off,1u);
#endif
  if(n<0&&errno==EINTR)continue;
  if(n<0&&errno==ENOSYS&&off==0)return legacy_entropy(out);
  if(n<=0||(size_t)n>12-off){if(n==0)errno=EIO;return -1;}off+=(size_t)n;
 }return 0;
#elif defined(__linux__)
 return legacy_entropy(out);
#elif defined(__APPLE__)
 return getentropy(out,12);
#else
 (void)out;errno=ENOSYS;return -1;
#endif
}
int hc_nonce_sequence_init(HCNonceSequence *s){
 uint8_t prefix[12];unsigned any=0;if(!s||s->active){errno=EINVAL;return -1;}
 if(entropy(prefix)!=0)return -1;for(size_t i=0;i<sizeof prefix;i++)any|=prefix[i];if(!any){errno=EIO;return -1;}
 if(pthread_mutex_init(&s->lock,NULL)!=0){errno=EIO;return -1;}
 memcpy(s->prefix,prefix,sizeof prefix);s->counter=0;s->process=getpid();s->active=1;return 0;
}
int hc_nonce_sequence_next(void *context,uint8_t out[16]){
 HCNonceSequence *s=context;uint8_t value[16];if(!s||!s->active||!out||s->process!=getpid()){errno=EINVAL;return -1;}
 if(pthread_mutex_lock(&s->lock)!=0){errno=EIO;return -1;}
 if(s->counter==UINT32_MAX){pthread_mutex_unlock(&s->lock);errno=EOVERFLOW;return -1;}
 uint32_t n=++s->counter;memcpy(value,s->prefix,12);value[12]=(uint8_t)(n>>24);value[13]=(uint8_t)(n>>16);value[14]=(uint8_t)(n>>8);value[15]=(uint8_t)n;
 if(pthread_mutex_unlock(&s->lock)!=0){errno=EIO;return -1;}memcpy(out,value,sizeof value);return 0;
}
int hc_nonce_sequence_destroy(HCNonceSequence *s){if(!s||!s->active||s->process!=getpid()){errno=EINVAL;return -1;}if(pthread_mutex_destroy(&s->lock)!=0){errno=EIO;return -1;}memset(s->prefix,0,sizeof s->prefix);s->counter=0;s->process=0;s->active=0;return 0;}
