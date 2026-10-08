#ifndef PNG_INPUT_H
#define PNG_INPUT_H
#include <stddef.h>
#include <stdint.h>
uint8_t *png_decode_input(const uint8_t *bytes, size_t count, size_t max_pixels, size_t *filtered_count);
#endif
