#include "include/safe_decode.h"
#include "minilzo.h"
int swift_hakchi_lzo_decode(const unsigned char *input, size_t input_count,
                           unsigned char *output, size_t output_count) {
    if (!input || !output || !input_count || !output_count ||
        input_count > 262144 || output_count > 262144) return -1;
    lzo_uint count = (lzo_uint)output_count;
    int result = lzo1x_decompress_safe(input, (lzo_uint)input_count, output, &count, NULL);
    return result == LZO_E_OK && count == output_count ? 0 : -1;
}
