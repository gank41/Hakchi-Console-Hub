#ifndef SWIFTHAKCHI_BOUNDED_REPLACE_H
#define SWIFTHAKCHI_BOUNDED_REPLACE_H
#include "../bounded-nand/bounded_nand_io.h"
#define BW_BYTES (BN_END-BN_START)
enum bw_status { BW_OK=0,BW_INVALID=1,BW_IO_ERROR=2,BW_MISMATCH=3 };
struct bw_io {
    int (*read)(void *,uint32_t,unsigned char *,uint32_t,uint32_t,uint32_t *);
    int (*write)(void *,uint32_t,const unsigned char *,uint32_t,uint32_t,uint32_t *);
    int (*flush)(void *);
};
int bw_replace(const struct bn_geometry *,const unsigned char expected[BW_BYTES],
               const unsigned char target[BW_BYTES],const struct bw_io *,void *,
               unsigned char scratch[BN_UNIT],int verify_only);
#endif
