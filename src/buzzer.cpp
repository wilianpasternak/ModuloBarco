#include "buzzer.h"

#include <atomic>
#include <string.h>
#include "driver/gpio.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "config.h"

struct Pattern {
  uint8_t n;
  BuzStep steps[BUZ_MAX_STEPS];
};

static QueueHandle_t     s_queue = nullptr;
static std::atomic<bool> s_enabled{true};

static inline void out(bool on) { gpio_set_level(PIN_BUZZER, on ? 1 : 0); }

// Espera 'ms' ou ate chegar um novo padrao (retorna true se chegou)
static bool wait_or_new(uint16_t ms, Pattern& p) {
  if (ms == 0) return false;
  TickType_t t = (ms == BUZ_HOLD) ? portMAX_DELAY : pdMS_TO_TICKS(ms);
  return xQueueReceive(s_queue, &p, t) == pdTRUE;
}

static void buzzer_task(void*) {
  Pattern p;
  for (;;) {
    xQueueReceive(s_queue, &p, portMAX_DELAY);
  restart:
    for (int i = 0; i < p.n; i++) {
      if (p.steps[i].on_ms) {
        out(true);
        if (wait_or_new(p.steps[i].on_ms, p)) { out(false); goto restart; }
      }
      out(false);
      if (wait_or_new(p.steps[i].off_ms, p)) goto restart;
    }
    out(false);
  }
}

void buzzer_init(bool enabled) {
  s_enabled = enabled;
  gpio_set_level(PIN_BUZZER, 0);
  gpio_config_t io = {};
  io.pin_bit_mask = 1ULL << PIN_BUZZER;
  io.mode = GPIO_MODE_OUTPUT;
  gpio_config(&io);
  out(false);
  s_queue = xQueueCreate(1, sizeof(Pattern));
  xTaskCreatePinnedToCore(buzzer_task, "buzzer", STACK_BUZZER, nullptr,
                          PRIO_BUZZER, nullptr, CORE_COMM);
}

void buzzer_set_enabled(bool enabled) {
  s_enabled = enabled;
  if (!enabled) buzzer_hold(false);
}

bool buzzer_enabled() { return s_enabled; }

static void send(const Pattern& p) {
  if (s_queue) xQueueOverwrite(s_queue, &p);
}

void buzzer_play(const BuzStep* steps, int n) {
  if (!s_enabled) return;
  Pattern p = {};
  p.n = (uint8_t)(n > BUZ_MAX_STEPS ? BUZ_MAX_STEPS : n);
  memcpy(p.steps, steps, p.n * sizeof(BuzStep));
  send(p);
}

void buzzer_beep(uint16_t ms) {
  BuzStep s = { ms, 0 };
  buzzer_play(&s, 1);
}

void buzzer_hold(bool on) {
  Pattern p = {};
  if (on) {
    if (!s_enabled) return;
    p.n = 1;
    p.steps[0] = { BUZ_HOLD, 0 };
  }
  send(p);   // n=0 -> desliga
}
