#include "screenshot_png.h"
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#define HC_PNG_MAX_FILE (8u * 1024u * 1024u)
#define HC_PNG_MAX_RAW_BYTES (16u * 1024u * 1024u)
static uint32_t be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}
int hc_screenshot_png(const uint8_t *p, size_t n) {
    static const uint8_t signature[] = {137,80,78,71,13,10,26,10};
    if (!p || n < 57 || n > HC_PNG_MAX_FILE || memcmp(p, signature, sizeof signature)) return -1;
    size_t pos = 8;
    const uint8_t *compressed = NULL;
    uint32_t width = 0, height = 0, compressed_length = 0;
    unsigned channels = 0;
    for (int chunk = 0; chunk < 3; ++chunk) {
        if (n - pos < 12) return -1;
        uint32_t length = be32(p + pos);
        if ((size_t)length > n - pos - 12) return -1;
        const uint8_t *type = p + pos + 4, *data = type + 4;
        const char *expected = chunk == 0 ? "IHDR" : chunk == 1 ? "IDAT" : "IEND";
        if (memcmp(type, expected, 4)) return -1;
        uLong crc = crc32(0L, Z_NULL, 0);
        crc = crc32(crc, type, (uInt)(4u + length));
        if ((uint32_t)crc != be32(data + length)) return -1;
        if (chunk == 0) {
            if (length != 13) return -1;
            width = be32(data); height = be32(data + 4);
            if (!width || !height || width > 4096 || height > 4096 || data[8] != 8 ||
                (data[9] != 2 && data[9] != 6) || data[10] || data[11] || data[12]) return -1;
            channels = data[9] == 2 ? 3 : 4;
        } else if (chunk == 1) {
            if (!length) return -1;
            compressed = data; compressed_length = length;
        } else if (length != 0) return -1;
        pos += (size_t)length + 12;
    }
    if (pos != n) return -1;
    uint64_t row = (uint64_t)width * channels + 1;
    uint64_t count = row * height;
    if (count > HC_PNG_MAX_RAW_BYTES) return -1;
    uint8_t *raw = malloc((size_t)count + 1);
    if (!raw) return -1;
    z_stream stream = {0};
    stream.next_in = (Bytef *)compressed; stream.avail_in = compressed_length;
    stream.next_out = raw; stream.avail_out = (uInt)count + 1;
    int result = inflateInit(&stream);
    if (result != Z_OK) { free(raw); return -1; }
    result = inflate(&stream, Z_FINISH);
    int good = result == Z_STREAM_END && stream.total_out == count && stream.avail_in == 0;
    if (inflateEnd(&stream) != Z_OK) good = 0;
    if (good) for (uint32_t y = 0; y < height; ++y) if (raw[(size_t)(row * y)] > 4) { good = 0; break; }
    free(raw);
    return good ? 0 : -1;
}
