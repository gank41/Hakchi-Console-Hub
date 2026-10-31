#ifndef SWIFTHAKCHI_BOUNDED_NAND_IO_H
#define SWIFTHAKCHI_BOUNDED_NAND_IO_H
#include <stdint.h>
#define BN_UNIT UINT32_C(0x20000)
#define BN_START UINT32_C(0x600000)
#define BN_END UINT32_C(0xd00000)
enum bn_status { BN_OK=0, BN_INVALID=1, BN_IO_ERROR=2 };
struct bn_geometry { uint32_t page_size, pages_per_block, block_count; };
struct bn_io {
    int (*read_block)(void *, uint32_t offset, unsigned char *, uint32_t length, uint32_t raw, uint32_t *bad_blocks);
    int (*output)(void *, const unsigned char *, uint32_t length);
};
int bn_check_geometry(const struct bn_geometry *);
/* Physical reads only. Geometry/bounds are refusal checks, never firmware authorization. */
int bn_read_units(const struct bn_geometry *, uint64_t offset, uint64_t bytes,
                  const struct bn_io *, void *, unsigned char buffer[BN_UNIT]);
#endif
