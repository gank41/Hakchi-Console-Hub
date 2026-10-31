#include "bounded_replace.h"
#ifdef NDEBUG
#error Assertions required
#endif
#include <assert.h>
#include <stdio.h>
#include <string.h>
static unsigned char disk[BW_BYTES],expected[BW_BYTES],target[BW_BYTES],scratch[BN_UNIT];
struct fixture {unsigned reads,writes,flushes;unsigned fault;uint32_t offsets[56];};
static int read_block(void *p,uint32_t offset,unsigned char *out,uint32_t length,uint32_t raw,uint32_t *bad) {
    struct fixture *f=p;assert(offset>=0x600000 && offset<=0xce0000 && offset%131072==0 && length==131072 && raw==1);
    ++f->reads;
    if(f->fault==1 && f->reads==56) return -1;
    if(f->fault==2 && f->reads==56) *bad=1;
    if(f->fault==3 && f->reads==57) disk[0]^=1;
    if(f->fault==6 && f->writes==1) return -1;
    if(f->fault==7 && f->writes==1) disk[offset-BN_START]^=1;
    if(f->fault==8 && f->writes==2 && f->reads==61) disk[BN_UNIT]^=1;
    memcpy(out,disk+(offset-BN_START),length);return 0;
}
static int write_block(void *p,uint32_t offset,const unsigned char *in,uint32_t length,uint32_t raw,uint32_t *bad) {
    struct fixture *f=p;assert(f->reads>=57 && f->writes<56 && offset>=0x600000 && offset<=0xce0000 && offset%131072==0 && length==131072 && raw==1);
    f->offsets[f->writes++]=offset;
    if(f->fault==4) {memcpy(disk+(offset-BN_START),in,length/2);return -1;}
    if(f->fault==9) {*bad=1;return 0;}
    memcpy(disk+(offset-BN_START),in,length);return 0;
}
static int flush(void *p) {struct fixture *f=p;++f->flushes;return (f->fault==5 && f->writes) || f->fault==10 ? -1:0;}
static void reset(struct fixture *f) {
    memset(f,0,sizeof *f);memset(disk,0x35,sizeof disk);memcpy(expected,disk,sizeof disk);memcpy(target,disk,sizeof disk);
    memset(target,0xa5,BN_UNIT);memset(target+BW_BYTES-BN_UNIT,0x77,BN_UNIT);
}
int main(void) {
    const struct bn_geometry g={2048,64,4096};const struct bw_io io={read_block,write_block,flush};struct fixture f;
    reset(&f);assert(bw_replace(&g,expected,target,&io,&f,scratch,0)==BW_OK);
    assert(f.writes==2 && f.offsets[0]==0x600000 && f.offsets[1]==0xce0000 && f.reads==116 && !memcmp(disk,target,sizeof disk));
    reset(&f);assert(bw_replace(&g,expected,target,&io,&f,scratch,1)==BW_OK && f.writes==0 && f.reads==56 && !memcmp(disk,expected,sizeof disk));
    reset(&f);memcpy(target,expected,sizeof target);assert(bw_replace(&g,expected,target,&io,&f,scratch,0)==BW_OK && !f.writes && f.reads==112);
    reset(&f);disk[BW_BYTES-1]^=1;assert(bw_replace(&g,expected,target,&io,&f,scratch,0)==BW_MISMATCH && f.writes==0 && f.reads==56);
    for(unsigned fault=1;fault<=10;++fault) {
        reset(&f);f.fault=fault;int result=bw_replace(&g,expected,target,&io,&f,scratch,0);
        assert(result==(fault==3 || fault==7 || fault==8 ? BW_MISMATCH:BW_IO_ERROR));
        assert(f.writes==(fault<=3 || fault==10 ? 0:fault==8 ? 2:1));
    }
    const struct bn_geometry bad={4096,64,4096};reset(&f);
    assert(bw_replace(&bad,expected,target,&io,&f,scratch,0)==BW_INVALID && !f.reads && !f.writes && !f.flushes);
    assert(bw_replace(&g,expected,target,&io,&f,(unsigned char *)expected,0)==BW_INVALID);
    assert(bw_replace(&g,expected,expected+1,&io,&f,scratch,0)==BW_INVALID);
    assert(bw_replace(&g,0,target,&io,&f,scratch,0)==BW_INVALID);
    assert(bw_replace(&g,expected,target,&io,&f,scratch,2)==BW_INVALID);
    puts("bounded replacement tests passed: fixed range, full preflight, exact readback, no retry");return 0;
}
