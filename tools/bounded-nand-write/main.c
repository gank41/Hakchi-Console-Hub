/* Dedicated fixed-range replacement. No caller path, offset, slot or retry. */
#define _GNU_SOURCE
#include "bounded_replace.h"
#include "mbedtls/sha256.h"
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>
#if !defined(__arm__) || !defined(__linux__) || __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error Requires little-endian Linux ARM EABI
#endif
_Static_assert(sizeof(void *)==4,"32-bit kernel ABI required");
struct __attribute__((packed)) param {void *buffer;uint32_t length,offset,flags;struct {void *buffer;uint32_t length;} __attribute__((packed)) oob;uint32_t badblocks;};
struct __attribute__((packed)) info {unsigned char magic[8];uint32_t size,page,per,blocks;};
_Static_assert(sizeof(struct param)==28,"NAND request ABI");
_Static_assert(sizeof(struct info)==24,"NAND geometry ABI");
static unsigned char input[24+2*BW_BYTES],scratch[BN_UNIT];
static int digest(const unsigned char *bytes,size_t count,const char *expected) {
    if(strlen(expected)!=64) return 0;
    for(unsigned i=0;i<64;++i) if(!((expected[i]>='0' && expected[i]<='9') || (expected[i]>='a' && expected[i]<='f'))) return 0;
    unsigned char hash[32];char hex[65];static const char alphabet[]="0123456789abcdef";
    if(mbedtls_sha256(bytes,count,hash,0)!=0) return 0;
    for(unsigned i=0;i<32;++i) {hex[i*2]=alphabet[hash[i]>>4];hex[i*2+1]=alphabet[hash[i]&15];}hex[64]=0;
    return !memcmp(hex,expected,65);
}
static int uuid(const char *s) {
    if(strlen(s)!=36) return 0;
    for(unsigned i=0;i<36;++i) {
        if(i==8 || i==13 || i==18 || i==23) {if(s[i]!='-') return 0;}
        else if(!((s[i]>='0' && s[i]<='9') || (s[i]>='A' && s[i]<='F'))) return 0;
    }
    return 1;
}
static int load_input(void) {
    size_t offset=0;
    while(offset<sizeof input) {
        ssize_t n=read(0,input+offset,sizeof input-offset);
        if(n<0 && errno==EINTR) continue;
        if(n<=0 || (size_t)n>sizeof input-offset) return 0;
        offset+=(size_t)n;
    }
    unsigned char extra;ssize_t n;
    do {n=read(0,&extra,1);} while(n<0 && errno==EINTR);
    return n==0; /* Complete immutable input and EOF BEFORE opening NAND. */
}
static int block_io(void *context,uint32_t offset,void *bytes,uint32_t length,uint32_t raw,uint32_t *bad,unsigned command) {
    if(offset<BN_START || offset>BN_END-BN_UNIT || offset%BN_UNIT || length!=BN_UNIT || raw!=1) return -1;
    struct param p;memset(&p,0,sizeof p);p.buffer=bytes;p.length=length;p.offset=offset;p.flags=1;
    if(ioctl(*(int *)context,command,&p)!=0) return -1;
    /* Only pinned driver tag bit0 is known; bad blocks are always fatal. */
    if(p.buffer!=bytes || p.length!=length || p.offset!=offset || (p.flags & ~1u) || p.oob.buffer || p.oob.length) return -1;
    *bad=p.badblocks;return 0;
}
static int read_block(void *c,uint32_t offset,unsigned char *out,uint32_t n,uint32_t raw,uint32_t *bad) {return block_io(c,offset,out,n,raw,bad,0x767c);}
static int write_block(void *c,uint32_t offset,const unsigned char *in,uint32_t n,uint32_t raw,uint32_t *bad) {return block_io(c,offset,(void *)in,n,raw,bad,0x767d);}
static int flush(void *c) {return fsync(*(int *)c);}
int main(int argc,char **argv) {
    if(argc!=6 || (strcmp(argv[1],"verify-active") && strcmp(argv[1],"replace-active")) || !uuid(argv[5])) return BW_INVALID;
    if(!load_input() || !digest(input,24,argv[4]) || !digest(input+24,BW_BYTES,argv[2]) || !digest(input+24+BW_BYTES,BW_BYTES,argv[3])) return BW_INVALID;
    struct info reviewed;memcpy(&reviewed,input,24);
    const struct bn_geometry g={reviewed.page,reviewed.per,reviewed.blocks};
    if(memcmp(reviewed.magic,"hakchi\0\0",8) || reviewed.size!=24 || bn_check_geometry(&g)!=BN_OK) return BW_INVALID;
    int verify=!strcmp(argv[1],"verify-active");
    int fd=open("/dev/nanda",(verify?O_RDONLY:O_RDWR)|O_NOFOLLOW|O_NONBLOCK);
    if(fd<0) return BW_IO_ERROR;
    int result=BW_IO_ERROR;struct stat st;
    if(fstat(fd,&st)==0 && S_ISBLK(st.st_mode)) {
        struct info actual;memset(&actual,0,sizeof actual);
        struct param q;memset(&q,0,sizeof q);q.buffer=&actual;q.length=24;
        if(ioctl(fd,0x7679,&q)==0 && q.buffer==&actual && q.length==24 && !q.offset && !q.flags && !q.oob.buffer && !q.oob.length && !q.badblocks) {
            if(memcmp(&actual,&reviewed,24)) result=BW_INVALID;
            else {const struct bw_io io={read_block,write_block,flush};result=bw_replace(&g,input+24,input+24+BW_BYTES,&io,&fd,scratch,verify);}
        }
    }
    if(close(fd)!=0) result=BW_IO_ERROR;
    if(result==BW_OK) {
        char marker[256];int length=snprintf(marker,sizeof marker,"SWIFTHAKCHI_SNES_WRITE_%s_V1 %s %s\n",verify?"PREFLIGHT":"VERIFIED",argv[5],argv[3]);
        if(length<=0 || (size_t)length>=sizeof marker) return BW_IO_ERROR;
        unsigned offset=0;
        while(offset<(unsigned)length) {
            ssize_t n=write(1,marker+offset,(unsigned)length-offset);
            if(n<0 && errno==EINTR) continue;
            if(n<=0 || (size_t)n>(unsigned)length-offset) return BW_IO_ERROR;
            offset+=(unsigned)n;
        }
    }
    return result;
}
