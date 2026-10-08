#include "include/ImageCodec.h"
#include "PNGInput.h"
#include <stdlib.h>
#include <string.h>
#include <png.h>
#include <turbojpeg.h>

static int bounded(int width, int height, size_t max_pixels) {
    return width > 0 && height > 0 && (size_t)width <= max_pixels / (size_t)height
        && (size_t)width <= SIZE_MAX / 4 / (size_t)height;
}

int image_decode(const uint8_t *bytes, size_t count, size_t max_pixels, DecodedImage *image) {
    memset(image, 0, sizeof(*image));
    if (max_pixels > IMAGE_CODEC_MAX_PIXELS) max_pixels = IMAGE_CODEC_MAX_PIXELS;
    if (count >= 8 && !png_sig_cmp(bytes, 0, 8)) {
        size_t filtered_count = 0;
        uint8_t *filtered = png_decode_input(bytes, count, max_pixels, &filtered_count);
        if (!filtered) return 0;
        png_image png = {0};
        png.version = PNG_IMAGE_VERSION;
        if (!png_image_begin_read_from_memory(&png, filtered, filtered_count)) {
            png_image_free(&png);
            free(filtered);
            return 0;
        }
        if (png.width > INT32_MAX || png.height > INT32_MAX
            || !bounded((int)png.width, (int)png.height, max_pixels)) {
            png_image_free(&png);
            free(filtered);
            return 0;
        }
        png.format = PNG_FORMAT_RGBA;
        uint8_t *pixels = malloc(PNG_IMAGE_SIZE(png));
        if (!pixels || !png_image_finish_read(&png, NULL, pixels, 0, NULL)
            || png.warning_or_error != 0) {
            free(pixels);
            png_image_free(&png);
            free(filtered);
            return 0;
        }
        image->pixels = pixels;
        image->width = (int)png.width;
        image->height = (int)png.height;
        image->is_png = 1;
        png_image_free(&png);
        free(filtered);
        return 1;
    }
    if (count < 2 || bytes[0] != 0xff || bytes[1] != 0xd8) return 0;
    // TurboJPEG catches libjpeg's longjmp inside its C API; no jump crosses Swift.
    tjhandle jpeg = tj3Init(TJINIT_DECOMPRESS);
    if (!jpeg) return 0;
    int ok = 0;
    uint8_t *pixels = NULL;
    if (tj3Set(jpeg, TJPARAM_STOPONWARNING, 1) < 0
        || tj3Set(jpeg, TJPARAM_SCANLIMIT, 100) < 0
        || tj3Set(jpeg, TJPARAM_MAXPIXELS, (int)max_pixels) < 0
        || tj3Set(jpeg, TJPARAM_MAXMEMORY, 128) < 0
        || tj3DecompressHeader(jpeg, bytes, count) < 0) goto done;
    int width = tj3Get(jpeg, TJPARAM_JPEGWIDTH);
    int height = tj3Get(jpeg, TJPARAM_JPEGHEIGHT);
    if (!bounded(width, height, max_pixels) || tj3Get(jpeg, TJPARAM_PRECISION) != 8) goto done;
    pixels = malloc((size_t)width * height * 4);
    if (!pixels || tj3Decompress8(jpeg, bytes, count, pixels, 0, TJPF_RGBA) < 0) goto done;
    image->pixels = pixels;
    image->width = width;
    image->height = height;
    ok = 1;
done:
    if (!ok) free(pixels);
    tj3Destroy(jpeg);
    return ok;
}

uint8_t *image_encode_png(const uint8_t *rgba, int width, int height, size_t *count) {
    if (!bounded(width, height, IMAGE_CODEC_MAX_PIXELS)) return NULL;
    png_image png = {0};
    png.version = PNG_IMAGE_VERSION;
    png.width = width;
    png.height = height;
    png.format = PNG_FORMAT_RGBA;
    png_alloc_size_t size = 0;
    if (!png_image_write_to_memory(&png, NULL, &size, 0, rgba, 0, NULL)) return NULL;
    uint8_t *bytes = malloc(size);
    if (!bytes) return NULL;
    if (!png_image_write_to_memory(&png, bytes, &size, 0, rgba, 0, NULL)) {
        free(bytes);
        return NULL;
    }
    *count = size;
    return bytes;
}

uint8_t *image_encode_jpeg(const uint8_t *rgba, int width, int height, int quality, size_t *count) {
    if (!bounded(width, height, IMAGE_CODEC_MAX_PIXELS)) return NULL;
    tjhandle jpeg = tj3Init(TJINIT_COMPRESS);
    if (!jpeg) return NULL;
    unsigned char *bytes = NULL;
    size_t size = 0;
    if (tj3Set(jpeg, TJPARAM_QUALITY, quality) < 0
        || tj3Set(jpeg, TJPARAM_SUBSAMP, TJSAMP_420) < 0
        || tj3Compress8(jpeg, rgba, width, 0, height, TJPF_RGBA, &bytes, &size) < 0) {
        tj3Free(bytes);
        tj3Destroy(jpeg);
        return NULL;
    }
    uint8_t *output = malloc(size);
    if (output) { memcpy(output, bytes, size); *count = size; }
    tj3Free(bytes);
    tj3Destroy(jpeg);
    return output;
}

void image_codec_free(void *bytes) { free(bytes); }
