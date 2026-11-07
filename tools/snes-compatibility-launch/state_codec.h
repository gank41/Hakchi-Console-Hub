#ifndef HAKCHI_SNES_STATE_CODEC_H
#define HAKCHI_SNES_STATE_CODEC_H
#include <stddef.h>

#define HC_STATE_BYTES_MAX (16u*1024u*1024u)
typedef struct {unsigned char *data;size_t length;} HCStateBytes;
#define HC_STATE_BYTES_INITIALIZER {NULL,0}
/* In-memory conversion only. The caller authenticates the game and state,
 * owns input bytes and uses an empty output object. Gzip validation does not
 * establish that a state is safe to load or that the console accepts it.
 * Failure leaves the output empty. Caller frees success using clear. */
int hc_state_gzip_encode(const void *,size_t,HCStateBytes *);
/* Decode one complete gzip member, or copy a bounded raw legacy state. Rejects
 * truncation, corrupt CRC/size, extra bytes and oversized output. */
int hc_state_decode(const void *,size_t,HCStateBytes *);
void hc_state_bytes_clear(HCStateBytes *);
#endif
