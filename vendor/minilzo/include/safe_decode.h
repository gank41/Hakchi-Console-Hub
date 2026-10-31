#ifndef SWIFT_HAKCHI_SAFE_LZO_H
#define SWIFT_HAKCHI_SAFE_LZO_H
#include <stddef.h>
int swift_hakchi_lzo_decode(const unsigned char *input, size_t input_count,
                           unsigned char *output, size_t output_count);
int swift_hakchi_lzo_encode(const unsigned char *input, size_t input_count,
                           unsigned char *output, size_t capacity, size_t *written);
#endif
