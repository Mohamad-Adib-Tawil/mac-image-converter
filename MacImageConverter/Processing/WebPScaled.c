#include "WebPScaled.h"
#include <stdlib.h>
#include <string.h>
#include "webp/decode.h"

uint8_t *IFWebPDecodeScaled(const uint8_t *data, size_t size, int max_dimension,
                           int *width, int *height) {
  int source_width = 0, source_height = 0;
  if (max_dimension <= 0 || !WebPGetInfo(data, size, &source_width, &source_height)) return NULL;
  double scale = (double)max_dimension / (double)(source_width > source_height ? source_width : source_height);
  if (scale > 1.0) scale = 1.0;
  const int target_width = (int)(source_width * scale) > 0 ? (int)(source_width * scale) : 1;
  const int target_height = (int)(source_height * scale) > 0 ? (int)(source_height * scale) : 1;
  if ((size_t)target_width > SIZE_MAX / 4 / (size_t)target_height) return NULL;

  WebPDecoderConfig config;
  if (!WebPInitDecoderConfig(&config)) return NULL;
  config.output.colorspace = MODE_RGBA;
  config.options.use_scaling = 1;
  config.options.scaled_width = target_width;
  config.options.scaled_height = target_height;
  if (WebPDecode(data, size, &config) != VP8_STATUS_OK) {
    WebPFreeDecBuffer(&config.output);
    return NULL;
  }
  const size_t row_bytes = (size_t)target_width * 4;
  uint8_t *result = malloc(row_bytes * (size_t)target_height);
  if (result != NULL) {
    for (int y = 0; y < target_height; ++y) {
      memcpy(result + (size_t)y * row_bytes,
             config.output.u.RGBA.rgba + (size_t)y * config.output.u.RGBA.stride,
             row_bytes);
    }
    *width = target_width;
    *height = target_height;
  }
  WebPFreeDecBuffer(&config.output);
  return result;
}

void IFWebPFree(void *pointer) { free(pointer); }
