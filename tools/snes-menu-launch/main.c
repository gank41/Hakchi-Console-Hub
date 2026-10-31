/* Fixed-purpose clean launch for the original SNES menu.
 * Linux ARM EABI, freestanding. No NAND access, ioctl, write or caller-selected
 * command exists here. The checked caller owns menu validation and switching.
 */
#define _GNU_SOURCE
#include <stddef.h>
#include <stdint.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/syscall.h>
#if !defined(__arm__) || !defined(__linux__) || __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error Requires little-endian 32-bit Linux ARM EABI
#endif
_Static_assert(sizeof(void *)==4 && sizeof(long)==4, "32-bit ABI required");
_Static_assert(O_DIRECTORY==(1<<14) && O_NOFOLLOW==(1<<15) && O_CLOEXEC==(1<<19), "Unexpected ARM open flags");
_Static_assert(SYS_rt_sigprocmask==175 && SYS_getdents64==217, "Unexpected ARM syscall ABI");
struct __attribute__((packed)) entry {
    uint64_t inode;
    int64_t offset;
    uint16_t length;
    uint8_t type;
    char name[];
};
_Static_assert(offsetof(struct entry,name)==19, "Unexpected getdents64 ABI");
static unsigned char directory[4096] __attribute__((aligned(8)));
static long call3(long number,long a,long b,long c) {
    register long r0 __asm__("r0")=a,r1 __asm__("r1")=b,r2 __asm__("r2")=c,r7 __asm__("r7")=number;
    __asm__ volatile("svc 0" : "+r"(r0) : "r"(r1),"r"(r2),"r"(r7) : "memory","cc");
    return r0;
}
static long call4(long number,long a,long b,long c,long d) {
    register long r0 __asm__("r0")=a,r1 __asm__("r1")=b,r2 __asm__("r2")=c,r3 __asm__("r3")=d,r7 __asm__("r7")=number;
    __asm__ volatile("svc 0" : "+r"(r0) : "r"(r1),"r"(r2),"r"(r3),"r"(r7) : "memory","cc");
    return r0;
}
/* Kernel-generated decimal descriptor names only; no pathname is acted on. */
static int descriptor(const char *s,size_t bound) {
    size_t length=0;
    while(length<bound && s[length])++length;
    if(length==bound || !length)return -2;
    if(s[0]=='.' && (length==1 || (length==2 && s[1]=='.')))return -1;
    if(length>7 || (length>1 && s[0]=='0'))return -2;
    unsigned value=0;
    for(size_t i=0;i<length;++i) {
        if(s[i]<'0' || s[i]>'9')return -2;
        value=value*10u+(unsigned)(s[i]-'0');
        if(value>1048575u)return -2;
    }
    return (int)value;
}
static int close_inherited(void) {
    long scan=call3(SYS_open,(long)"/proc/self/fd",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC,0);
    if(scan<0)return -1;
    unsigned entries=0;
    for(unsigned iteration=0;iteration<1024;++iteration) {
        long count=call3(SYS_getdents64,scan,(long)directory,sizeof directory);
        if(count<0 || count>(long)sizeof directory)break;
        if(!count)return call3(SYS_close,scan,0,0)==0 ? 0:-1;
        size_t cursor=0;
        while(cursor<(size_t)count) {
            if((size_t)count-cursor<offsetof(struct entry,name)+1)goto failed;
            struct entry *e=(struct entry *)(directory+cursor);
            if(e->length<offsetof(struct entry,name)+1 || e->length>(size_t)count-cursor || ++entries>4096)goto failed;
            int fd=descriptor(e->name,e->length-offsetof(struct entry,name));
            if(fd==-2)goto failed;
            if(fd>2 && fd!=scan) {
                long result=call3(SYS_close,fd,0,0);
                if(result!=0 && result!=-9)goto failed; /* EBADF is already closed. */
            }
            cursor+=e->length;
        }
    }
failed:
    (void)call3(SYS_close,scan,0,0);
    return -1;
}
__attribute__((used)) int menu_start(unsigned long *stack) {
    if(stack[0]!=1)return 64;
    if(close_inherited()!=0)return 65;
    uint32_t empty[2]={0,0},actual[2]={UINT32_MAX,UINT32_MAX};
    if(call4(SYS_rt_sigprocmask,SIG_SETMASK,(long)empty,0,sizeof empty)!=0)return 66;
    if(call4(SYS_rt_sigprocmask,SIG_SETMASK,0,(long)actual,sizeof actual)!=0 || actual[0] || actual[1])return 67;
    char *const argv[]={"/mnt/swifthakchi/busybox","sh","-e","/mnt/swifthakchi/menu-wrapper","start",0};
    char *const env[]={"PATH=/bin:/sbin:/usr/bin:/usr/sbin","LC_ALL=C",0};
    (void)call3(SYS_execve,(long)argv[0],(long)argv,(long)env);
    return 68;
}
__attribute__((naked,noreturn)) void _start(void) {
    __asm__ volatile("mov r0, sp\nbl menu_start\nmov r7, #1\nsvc 0\nb .");
}
