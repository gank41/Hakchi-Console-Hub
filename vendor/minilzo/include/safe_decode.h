#ifndef SWIFT_HAKCHI_SAFE_LZO_H
#define SWIFT_HAKCHI_SAFE_LZO_H
#include <stddef.h>
#include <stdint.h>
int swift_hakchi_lzo_decode(const unsigned char *input, size_t input_count,
                           unsigned char *output, size_t output_count);
int swift_hakchi_lzo_encode(const unsigned char *input, size_t input_count,
                           unsigned char *output, size_t capacity, size_t *written);
uint32_t swift_hakchi_lzo_adler32(const unsigned char *input, size_t input_count);
#endif
