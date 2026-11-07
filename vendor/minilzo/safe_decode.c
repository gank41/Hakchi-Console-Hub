#include "include/safe_decode.h"
#include "minilzo.h"
uint32_t swift_hakchi_lzo_adler32(const unsigned char *input, size_t input_count) {
    if (!input) return input_count == 0 ? 1 : 0;
    lzo_uint32_t checksum = 1;
    while (input_count) {
        size_t chunk = input_count > 262144 ? 262144 : input_count;
        checksum = lzo_adler32(checksum, input, (lzo_uint)chunk);
        input += chunk;
        input_count -= chunk;
    }
    return (uint32_t)checksum;
}
int swift_hakchi_lzo_decode(const unsigned char *input, size_t input_count,
                           unsigned char *output, size_t output_count) {
    if (!input || !output || !input_count || !output_count ||
        input_count > 262144 || output_count > 262144) return -1;
    lzo_uint count = (lzo_uint)output_count;
    int result = lzo1x_decompress_safe(input, (lzo_uint)input_count, output, &count, NULL);
    return result == LZO_E_OK && count == output_count ? 0 : -1;
}
