#include "bounded_nand_io.h"
static int power_of_two(uint32_t value) { return value && !(value & (value-1)); }
int bn_check_geometry(const struct bn_geometry *g) {
    if(!g || !power_of_two(g->page_size) || !power_of_two(g->pages_per_block) ||
       g->page_size<512 || g->page_size>16384 ||
       (uint64_t)g->page_size*g->pages_per_block!=BN_UNIT ||
       (uint64_t)g->block_count*BN_UNIT<BN_END) return BN_INVALID;
    return BN_OK;
}
int bn_read_units(const struct bn_geometry *g, uint64_t offset, uint64_t bytes,
                  const struct bn_io *io, void *context, unsigned char buffer[BN_UNIT]) {
    if(bn_check_geometry(g)!=BN_OK || !io || !io->read_block || !io->output || !buffer ||
       offset<BN_START || offset>=BN_END || offset%BN_UNIT ||
       !bytes || bytes%BN_UNIT || bytes>BN_END-offset) return BN_INVALID;
    const uint64_t end=offset+bytes; /* Addition is safe only after the subtraction check. */
    while(offset<end) {
        uint32_t bad=0;
        /* Repeat the physical bound at the actual callback boundary. Never relocate. */
        if(offset<BN_START || offset>BN_END-BN_UNIT) return BN_INVALID;
        if(io->read_block(context,(uint32_t)offset,buffer,BN_UNIT,1,&bad)!=0 || bad!=0) return BN_IO_ERROR;
        if(io->output(context,buffer,BN_UNIT)!=0) return BN_IO_ERROR;
        offset+=BN_UNIT;
    }
    return BN_OK;
}
