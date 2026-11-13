// ================================================================
//  Utilitarios de tempo e matematica
// ================================================================
#pragma once
#include <stdint.h>
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#ifndef PESCAPLUS_HAVE_MILLIS
#define PESCAPLUS_HAVE_MILLIS
static inline uint32_t millis() { return (uint32_t)(esp_timer_get_time() / 1000ULL); }
#endif

static inline void delay_ms(uint32_t ms) { vTaskDelay(pdMS_TO_TICKS(ms)); }

template <typename T>
static inline T clampv(T v, T lo, T hi) { return v < lo ? lo : (v > hi ? hi : v); }

// Normaliza um erro angular para [-180, 180)
static inline float wrap180(float e) {
  if (e >  180.0f) e -= 360.0f;
  if (e < -180.0f) e += 360.0f;
  return e;
}

// Normaliza um angulo para [0, 360)
static inline float wrap360(float a) {
  if (a <   0.0f) a += 360.0f;
  if (a >= 360.0f) a -= 360.0f;
  return a;
}
