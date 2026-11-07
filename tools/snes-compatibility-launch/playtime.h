#ifndef HAKCHI_SNES_PLAYTIME_H
#define HAKCHI_SNES_PLAYTIME_H
#include <stddef.h>
#include <stdint.h>
/* Numeric helpers only. They do not authenticate, open, or publish a file,
 * establish a console format, or authorize compatibility gameplay. */
typedef struct { uint64_t seconds; uint32_t nanoseconds; } HCPlaytimeInstant;
/* Unsigned decimal ASCII, optionally followed by one LF. Output unchanged on
 * failure; callers must verify file identity, origin, and the applicable unit. */
int hc_playtime_parse(const void *, size_t, uint64_t *);
/* Read a held, read-only regular file twice and reject unexpected ownership,
 * links, permissions, size, or changing bytes. The caller authenticates its
 * name and parent and excludes concurrent writers. Output is unchanged on
 * failure; this does not establish file provenance or authorize restoration. */
int hc_playtime_read(int, uint64_t *);
/* Accumulate whole elapsed monotonic seconds, rejecting invalid or backwards
 * instants and overflow. Output unchanged on failure. */
int hc_playtime_accumulate(uint64_t, HCPlaytimeInstant, HCPlaytimeInstant, uint64_t *);
/* Emit decimal ASCII without newline or terminator. Caller provides distinct
 * storage for bytes and length. Neither output changes on failure. */
int hc_playtime_format(uint64_t, void *, size_t, size_t *);
#endif
