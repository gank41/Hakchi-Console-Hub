#include "bounded_replace.h"
static int same(const unsigned char *a,const unsigned char *b,uint32_t n) {
    while(n--) {if(*a++!=*b++) return 0;} return 1;
}
static int overlaps(const unsigned char *a,uint32_t an,const unsigned char *b,uint32_t bn) {
    uintptr_t x=(uintptr_t)a,y=(uintptr_t)b;
    if(x>UINTPTR_MAX-an || y>UINTPTR_MAX-bn) return 1;
    return x<y+bn && y<x+an;
}
static int read_checked(const struct bw_io *io,void *context,uint32_t offset,unsigned char *scratch,const unsigned char *expected) {
    uint32_t bad=0;
    if(offset<BN_START || offset>BN_END-BN_UNIT || offset%BN_UNIT) return BW_INVALID;
    if(io->read(context,offset,scratch,BN_UNIT,1,&bad)!=0 || bad) return BW_IO_ERROR;
    return same(scratch,expected,BN_UNIT) ? BW_OK:BW_MISMATCH;
}
int bw_replace(const struct bn_geometry *g,const unsigned char *expected,const unsigned char *target,
               const struct bw_io *io,void *context,unsigned char *scratch,int verify_only) {
    if(bn_check_geometry(g)!=BN_OK || !expected || !target || !scratch || !io || !io->read || !io->flush ||
       (!verify_only && !io->write) || (verify_only!=0 && verify_only!=1) ||
       overlaps(scratch,BN_UNIT,expected,BW_BYTES) || overlaps(scratch,BN_UNIT,target,BW_BYTES) ||
       (expected!=target && overlaps(expected,BW_BYTES,target,BW_BYTES))) return BW_INVALID;
    if(io->flush(context)!=0) return BW_IO_ERROR;
    /* Verify the ENTIRE before-state before allowing the first mutation. */
    for(uint32_t n=0;n<BW_BYTES;n+=BN_UNIT) {
        int status=read_checked(io,context,BN_START+n,scratch,expected+n);
        if(status!=BW_OK) return status;
    }
    if(verify_only) return BW_OK;
    for(uint32_t n=0;n<BW_BYTES;n+=BN_UNIT) {
        if(same(expected+n,target+n,BN_UNIT)) continue;
        int status=read_checked(io,context,BN_START+n,scratch,expected+n);
        if(status!=BW_OK) return status;
        uint32_t bad=0,offset=BN_START+n;
        if(offset<BN_START || offset>BN_END-BN_UNIT) return BW_INVALID;
        if(io->write(context,offset,target+n,BN_UNIT,1,&bad)!=0 || bad || io->flush(context)!=0) return BW_IO_ERROR;
        status=read_checked(io,context,offset,scratch,target+n);
        if(status!=BW_OK) return status;
    }
    /* Also verify every untouched unit, including the preserved trailing area. */
    for(uint32_t n=0;n<BW_BYTES;n+=BN_UNIT) {
        int status=read_checked(io,context,BN_START+n,scratch,target+n);
        if(status!=BW_OK) return status;
    }
    return BW_OK;
}
