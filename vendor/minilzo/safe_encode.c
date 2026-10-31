#include "include/safe_decode.h"
#include "lzo999/include/lzo/lzo1x.h"
#include <stdlib.h>

/* Upstream LZO output bound; one 256 KiB container block at a time. */
int swift_hakchi_lzo_encode(const unsigned char *input, size_t input_count,
                           unsigned char *output, size_t capacity, size_t *written) {
    if (written) *written = 0;
    if (!input || !output || !written || !input_count || input_count > 262144) return -1;
    size_t bound = input_count + input_count / 16 + 64 + 3;
    if (capacity < bound || lzo_init() != LZO_E_OK) return -1;
    void *work = calloc(1, LZO1X_999_MEM_COMPRESS);
    if (!work) return -1;
    lzo_uint count = 0;
    int result = lzo1x_999_compress(input, (lzo_uint)input_count, output, &count, work);
    free(work);
    if (result != LZO_E_OK || count == 0 || count > bound) return -1;
    *written = (size_t)count;
    return 0;
}
