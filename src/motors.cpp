#include "motors.h"

#include "driver/gpio.h"
#include "driver/ledc.h"
#include "esp_log.h"
#include "config.h"

static const char* TAG = "motors";

static constexpr ledc_mode_t  MODE  = LEDC_HIGH_SPEED_MODE;
static constexpr ledc_timer_t TIMER = LEDC_TIMER_0;
static constexpr uint32_t     DUTY_MAX = (1u << PWM_BITS);   // 256 = 100%

static const ledc_channel_t CH[3]  = { LEDC_CHANNEL_0, LEDC_CHANNEL_1, LEDC_CHANNEL_2 };
static const gpio_num_t     PIN[3] = { PIN_GIRO_LEFT, PIN_GIRO_RIGHT, PIN_ACELERADOR };
static int s_last[3] = { -1, -1, -1 };

void motors_init() {
  // Reles: nivel HIGH gravado ANTES de virar saida -> sem pulso no boot
  gpio_set_level(PIN_UP, 1);
  gpio_set_level(PIN_DOWN, 1);
  gpio_config_t io = {};
  io.pin_bit_mask = (1ULL << PIN_UP) | (1ULL << PIN_DOWN);
  io.mode = GPIO_MODE_OUTPUT;
  ESP_ERROR_CHECK(gpio_config(&io));
  gpio_set_level(PIN_UP, 1);
  gpio_set_level(PIN_DOWN, 1);

  ledc_timer_config_t t = {};
  t.speed_mode      = MODE;
  t.duty_resolution = (ledc_timer_bit_t)PWM_BITS;
  t.timer_num       = TIMER;
  t.freq_hz         = PWM_FREQ_HZ;
  t.clk_cfg         = LEDC_AUTO_CLK;
  ESP_ERROR_CHECK(ledc_timer_config(&t));

  for (int i = 0; i < 3; i++) {
    ledc_channel_config_t c = {};
    c.gpio_num   = PIN[i];
    c.speed_mode = MODE;
    c.channel    = CH[i];
    c.timer_sel  = TIMER;
    c.duty       = 0;
    c.hpoint     = 0;
    ESP_ERROR_CHECK(ledc_channel_config(&c));
    s_last[i] = 0;
  }
  ESP_LOGI(TAG, "PWM %d Hz / %d bits — reles desligados", PWM_FREQ_HZ, PWM_BITS);
}

void motorWrite(Out out, int duty) {
  int i = (int)out;
  if (duty < 0) duty = 0;
  if (duty > 255) duty = 255;
  if (duty == s_last[i]) return;          // evita reescrever o mesmo duty a cada ciclo
  s_last[i] = duty;
  // Igual ao ledcWrite do Arduino 2.x: 255 em 8 bits vira 100% (duty = 256)
  uint32_t d = (duty == 255) ? DUTY_MAX : (uint32_t)duty;
  ledc_set_duty(MODE, CH[i], d);
  ledc_update_duty(MODE, CH[i]);
}

void relayUp(bool active)   { gpio_set_level(PIN_UP,   active ? 0 : 1); }
void relayDown(bool active) { gpio_set_level(PIN_DOWN, active ? 0 : 1); }

void motors_all_off() {
  motorWrite(Out::Left, 0);
  motorWrite(Out::Right, 0);
  motorWrite(Out::Throttle, 0);
  relayUp(false);
  relayDown(false);
}
