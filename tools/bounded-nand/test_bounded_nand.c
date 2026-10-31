#include "bounded_nand_io.h"
#ifdef NDEBUG
#error Tests require assertions enabled
#endif
#include <assert.h>
#include <stdio.h>
#include <string.h>

extern int bn_check_geometry(const struct bn_geometry *);

struct fixture { unsigned calls, outputs; uint32_t offsets[56]; unsigned fail, bad, output_fail; };
static int read_block(void *opaque, uint32_t offset, unsigned char *buffer, uint32_t length, uint32_t raw, uint32_t *bad) {
    struct fixture *f=opaque;
    assert(length==131072 && raw==1 && f->calls<56);
    f->offsets[f->calls++]=offset;
    if(f->calls==f->fail) return -1;
    *bad=f->calls==f->bad;
    memset(buffer, (int)(offset/131072), length);
    return 0;
}
static int output(void *opaque, const unsigned char *buffer, uint32_t length) {
    struct fixture *f=opaque;
    assert(length==131072 && buffer[0]==f->offsets[f->outputs]/131072 && buffer[length-1]==buffer[0]);
    ++f->outputs;return f->outputs==f->output_fail ? -1:0;
}
int main(void) {
    const struct bn_geometry g={2048,64,4096};
    assert(bn_check_geometry(&g)==BN_OK);
    assert(bn_check_geometry(NULL)==BN_INVALID);
    const struct bn_io io={read_block,output};
    unsigned char buffer[131072];
    struct fixture f={0};
    assert(bn_read_units(&g,0x600000,0x700000,&io,&f,buffer)==BN_OK);
    assert(f.calls==56 && f.outputs==56 && f.offsets[0]==0x600000 && f.offsets[55]==0xce0000);
    const uint64_t invalid[][2]={{0x600000,0},{0x5e0000,0x20000},{0x600001,0x20000},{0x600000,1},
        {0x600000,0x700001},{0xd00000,0x20000},{UINT64_MAX,0x20000},{0x600000,UINT64_MAX}};
    for(unsigned i=0;i<sizeof(invalid)/sizeof(invalid[0]);++i) {
        memset(&f,0,sizeof f);
        assert(bn_read_units(&g,invalid[i][0],invalid[i][1],&io,&f,buffer)==BN_INVALID);
        assert(f.calls==0 && f.outputs==0);
    }
    const struct bn_geometry malformed[]={{0,64,4096},{2048,0,4096},{UINT32_MAX,UINT32_MAX,4096},
        {4096,64,4096},{2048,64,1},{3,43690,4096}};
    for(unsigned i=0;i<sizeof(malformed)/sizeof(malformed[0]);++i) {
        assert(bn_check_geometry(&malformed[i])==BN_INVALID);
        memset(&f,0,sizeof f);
        assert(bn_read_units(&malformed[i],0x600000,0x20000,&io,&f,buffer)==BN_INVALID);
        assert(f.calls==0);
    }
    memset(&f,0,sizeof f);
    assert(bn_read_units(&g,0xce0000,0x20000,&io,&f,buffer)==BN_OK && f.calls==1);
    for(unsigned fault=0;fault<2;++fault) {
        memset(&f,0,sizeof f); if(fault) f.bad=2;else f.fail=2;
        assert(bn_read_units(&g,0x600000,0x700000,&io,&f,buffer)==BN_IO_ERROR);
        assert(f.calls==2 && f.outputs==1 && f.offsets[1]==0x620000);
    }
    memset(&f,0,sizeof f); f.output_fail=2;
    assert(bn_read_units(&g,0x600000,0x700000,&io,&f,buffer)==BN_IO_ERROR);
    assert(f.calls==2 && f.outputs==2); /* No third read after the failed output. */
    assert(bn_read_units(NULL,0x600000,0x20000,&io,&f,buffer)==BN_INVALID);
    puts("bounded physical NAND read tests passed");
    return 0;
}
