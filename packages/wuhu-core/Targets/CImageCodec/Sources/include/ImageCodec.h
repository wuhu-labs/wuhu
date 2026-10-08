#ifndef IMAGE_CODEC_H
#define IMAGE_CODEC_H
#include <stddef.h>
#include <stdint.h>
#define IMAGE_CODEC_MAX_PIXELS 40000000
typedef struct {
    uint8_t *pixels;
    int width;
    int height;
    int is_png;
} DecodedImage;
int image_decode(const uint8_t *bytes, size_t count, size_t max_pixels, DecodedImage *image);
uint8_t *image_encode_png(const uint8_t *rgba, int width, int height, size_t *count);
uint8_t *image_encode_jpeg(const uint8_t *rgba, int width, int height, int quality, size_t *count);
void image_codec_free(void *bytes);
#endif
