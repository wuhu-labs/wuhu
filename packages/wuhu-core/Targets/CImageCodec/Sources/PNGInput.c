#include "PNGInput.h"
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

static uint32_t big_endian(const uint8_t *bytes) {
    return (uint32_t)bytes[0] << 24 | (uint32_t)bytes[1] << 16
        | (uint32_t)bytes[2] << 8 | bytes[3];
}

static int retain(const uint8_t *type, size_t length) {
    if (!memcmp(type, "IHDR", 4)) return length == 13 ? 1 : -1;
    if (!memcmp(type, "PLTE", 4)) return length && length <= 768 && length % 3 == 0 ? 1 : -1;
    if (!memcmp(type, "IDAT", 4)) return 1;
    if (!memcmp(type, "IEND", 4)) return length == 0 ? 1 : -1;
    if (!memcmp(type, "tRNS", 4)) return length <= 256 ? 1 : -1;
    if (!memcmp(type, "gAMA", 4)) return length == 4 ? 1 : -1;
    if (!memcmp(type, "cHRM", 4)) return length == 32 ? 1 : -1;
    if (!memcmp(type, "sRGB", 4)) return length == 1 ? 1 : -1;
    return type[0] & 32 ? 0 : -1;
}

uint8_t *png_decode_input(const uint8_t *bytes, size_t count, size_t max_pixels, size_t *filtered_count) {
    if (count < 33 || memcmp(bytes, "\x89PNG\r\n\x1a\n", 8)
        || big_endian(bytes + 8) != 13 || memcmp(bytes + 12, "IHDR", 4)) return NULL;
    uint32_t width = big_endian(bytes + 16), height = big_endian(bytes + 20);
    if (!width || !height || width > INT32_MAX || height > INT32_MAX
        || width > max_pixels / height || width > SIZE_MAX / 4 / height) return NULL;
    size_t offset = 8, output_count = 8;
    int ended = 0;
    while (count - offset >= 12) {
        size_t length = big_endian(bytes + offset);
        if (length > count - offset - 12) return NULL;
        const uint8_t *type = bytes + offset + 4;
        for (int i = 0; i < 4; i++) {
            if (!((type[i] >= 'A' && type[i] <= 'Z') || (type[i] >= 'a' && type[i] <= 'z'))) return NULL;
        }
        uLong crc = crc32(0, type, 4);
        crc = crc32(crc, type + 4, (uInt)length);
        if ((uint32_t)crc != big_endian(type + 4 + length)) return NULL;
        int keep = retain(type, length);
        if (keep < 0) return NULL;
        if (keep) output_count += length + 12;
        offset += length + 12;
        if (!memcmp(type, "IEND", 4)) { ended = 1; break; }
    }
    if (!ended || offset != count) return NULL;
    // No compressed ancillary payload reaches libpng, which otherwise expands it during begin-read.
    uint8_t *output = malloc(output_count);
    if (!output) return NULL;
    memcpy(output, bytes, 8);
    size_t written = 8;
    for (offset = 8; offset < count;) {
        size_t length = big_endian(bytes + offset);
        if (retain(bytes + offset + 4, length)) {
            memcpy(output + written, bytes + offset, length + 12);
            written += length + 12;
        }
        offset += length + 12;
    }
    *filtered_count = written;
    return output;
}
