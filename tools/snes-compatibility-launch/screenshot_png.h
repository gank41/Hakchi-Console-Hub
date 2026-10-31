#ifndef HAKCHI_SCREENSHOT_PNG_H
#define HAKCHI_SCREENSHOT_PNG_H
#include <stddef.h>
#include <stdint.h>
/* Validates the bounded, single-IDAT, RGB/RGBA, noninterlaced PNG shape
 * produced by the pinned frontend, including chunk CRCs and decompression.
 * Caller must supply stable owned bytes. Success does not prove freshness,
 * frontend task completion, device durability, or correctness of picture. */
int hc_screenshot_png(const uint8_t *bytes, size_t length);
#endif
