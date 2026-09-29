#pragma once
#include <stddef.h>
#include <stdint.h>

// Returns malloc-owned, tightly packed RGBA pixels. Call IFWebPFree.
uint8_t *IFWebPDecodeScaled(const uint8_t *data, size_t size, int max_dimension,
                           int *width, int *height);
void IFWebPFree(void *pointer);
