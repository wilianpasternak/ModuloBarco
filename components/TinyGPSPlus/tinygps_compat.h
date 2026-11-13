// ================================================================
//  Shim minimo para compilar a TinyGPSPlus 1.1.0 (LGPL-2.1) sem o
//  framework Arduino. Fornece millis() (esp_timer) e o tipo byte.
// ================================================================
#pragma once
#include <stdint.h>
#include <math.h>
#include "esp_timer.h"

typedef uint8_t byte;

#ifndef PESCAPLUS_HAVE_MILLIS
#define PESCAPLUS_HAVE_MILLIS
static inline uint32_t millis() { return (uint32_t)(esp_timer_get_time() / 1000ULL); }
#endif
