/* Linux ARM EABI, freestanding, read-only. No write/erase/burn ioctl exists here.
 * ABI corroboration: cached hakchi sntool/nand_blk sources; see README.md.
 * This developer primitive has no console identity or installation capability.
 */
#include "bounded_nand_io.h"
#if !defined(__arm__) || !defined(__linux__) || __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error This read-only executable requires little-endian Linux ARM EABI
#endif
_Static_assert(sizeof(void *)==4, "32-bit kernel ABI required");
struct __attribute__((packed)) bn_param {
    void *buffer;
    uint32_t length, offset, flags;
    struct { void *buffer; uint32_t length; } __attribute__((packed)) oob;
    uint32_t badblocks;
};
struct __attribute__((packed)) bn_info { unsigned char magic[8]; uint32_t size,page_size,pages_per_block,block_count; };
_Static_assert(sizeof(struct bn_param)==28, "NAND ioctl ABI mismatch");
_Static_assert(sizeof(struct bn_info)==24, "NAND geometry ABI mismatch");
static unsigned char buffer[BN_UNIT];
static long syscall3(long number,long a,long b,long c) {
    register long r0 __asm__("r0")=a, r1 __asm__("r1")=b, r2 __asm__("r2")=c, r7 __asm__("r7")=number;
    __asm__ volatile("svc 0" : "+r"(r0) : "r"(r1),"r"(r2),"r"(r7) : "memory","cc");
    return r0;
}
static int equal(const char *a,const char *b) { while(*a && *a==*b) { ++a;++b; } return *a==*b; }
static void clear(void *pointer,unsigned count) { unsigned char *p=pointer;while(count--) *p++=0; }
static int output(void *unused,const unsigned char *p,uint32_t length) {
    (void)unused;
    while(length) {
        long n=syscall3(4,1,(long)p,length);
        if(n==-4) continue; /* EINTR retries stdout only; never repeat a NAND ioctl. */
        if(n<=0 || (uint32_t)n>length) return -1;
        p+=n;length-=(uint32_t)n;
    }
    return 0;
}
static int read_block(void *context,uint32_t offset,unsigned char *p,uint32_t length,uint32_t raw,uint32_t *bad) {
    const int fd=*(const int *)context;
    struct bn_param request;clear(&request,sizeof request);
    request.buffer=p;request.length=length;request.offset=offset;request.flags=raw;
    if(syscall3(54,fd,0x767c,(long)&request)!=0) return -1;
    /* Pinned driver sets output bit 0 when spare-area byte 1 is nonzero.
     * It is a tag observation, independent of badblocks; reject all unknown bits. */
    if(request.buffer!=p || request.length!=length || request.offset!=offset || (request.flags & ~1u)!=0 ||
       request.oob.buffer || request.oob.length) return -1;
    *bad=request.badblocks;return 0;
}
__attribute__((used)) int bn_start(unsigned long *stack) {
    const unsigned long argc=stack[0];const char *const *argv=(const char *const *)(stack+1);
    const int geometry_only=argc==2 && equal(argv[1],"geometry");
    if(!geometry_only && (argc!=3 || !equal(argv[1],"read-active"))) return BN_INVALID;
    uint32_t count=0;
    if(!geometry_only) {
        const char *p=argv[2];if(!*p) return BN_INVALID;
        while(*p) { if(*p<'0' || *p>'9' || count>56) return BN_INVALID;count=count*10+(uint32_t)(*p++-'0'); }
        if(count<1 || count>56) return BN_INVALID;
    }
    /* Fixed node, read-only, O_NONBLOCK|O_NOFOLLOW. No caller path accepted. */
    const int fd=(int)syscall3(5,(long)"/dev/nanda",0x20800,0);
    if(fd<0) return BN_IO_ERROR;
    struct bn_info info;clear(&info,sizeof info);
    struct bn_param query;clear(&query,sizeof query);query.buffer=&info;query.length=sizeof info;
    int status=BN_IO_ERROR;
    if(syscall3(54,fd,0x7679,(long)&query)==0 && info.size==sizeof info &&
       info.magic[0]=='h' && info.magic[1]=='a' && info.magic[2]=='k' && info.magic[3]=='c' &&
       info.magic[4]=='h' && info.magic[5]=='i' && !info.magic[6] && !info.magic[7] &&
       query.buffer==&info && query.length==sizeof info && !query.offset && !query.flags &&
       !query.oob.buffer && !query.oob.length && !query.badblocks) {
        const struct bn_geometry geometry={info.page_size,info.pages_per_block,info.block_count};
        const struct bn_io io={read_block,output};
        status=bn_check_geometry(&geometry);
        if(status==BN_OK) {
            if(geometry_only) status=output(0,(const unsigned char *)&info,sizeof info)==0 ? BN_OK:BN_IO_ERROR;
            else status=bn_read_units(&geometry,BN_START,(uint64_t)count*BN_UNIT,&io,(void *)&fd,buffer);
        }
    }
    if(syscall3(6,fd,0,0)!=0) status=BN_IO_ERROR;
    return status;
}
__attribute__((naked,noreturn)) void _start(void) {
    __asm__ volatile("mov r0, sp\nbl bn_start\nmov r7, #1\nsvc 0\nb .");
}
