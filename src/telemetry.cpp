#include "telemetry.h"

#include <math.h>
#include <stdio.h>
#include "esp_adc/adc_oneshot.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "anchor.h"
#include "ble.h"
#include "config.h"
#include "control.h"
#include "gps.h"
#include "util.h"

static const char* TAG = "telemetry";

static adc_oneshot_unit_handle_t s_adc = nullptr;
static constexpr adc_channel_t BAT_CH = ADC_CHANNEL_6;   // GPIO34

static portMUX_TYPE s_mux = portMUX_INITIALIZER_UNLOCKED;
static float s_batVoltage = 0.0f;
static int   s_batPercent = -1;

// Curva SoC para bateria chumbo-acido 12V (tensao em repouso)
static int volt_to_soc_pb(float v) {
  static const float vt[] = {10.50f,11.51f,11.66f,11.81f,11.96f,12.10f,12.24f,12.37f,12.50f,12.62f,12.73f};
  static const int   st[] = {0,     10,    20,    30,    40,    50,    60,    70,    80,    90,    100};
  const int n = 11;
  if (v <= vt[0])   return 0;
  if (v >= vt[n-1]) return 100;
  for (int i = 1; i < n; i++) {
    if (v < vt[i]) {
      float frac = (v - vt[i-1]) / (vt[i] - vt[i-1]);
      return st[i-1] + (int)(frac * (float)(st[i] - st[i-1]));
    }
  }
  return 100;
}

// Media de 16 leituras raw (0..4095), como o analogRead do Arduino
static float read_battery_volts() {
  long sum = 0;
  int n = 0;
  for (int i = 0; i < 16; i++) {
    int raw;
    if (adc_oneshot_read(s_adc, BAT_CH, &raw) == ESP_OK) { sum += raw; n++; }
  }
  if (n == 0) return 0.0f;
  float vAdc = (sum / (float)n / 4095.0f) * 3.3f;
  return clampv(vAdc * BAT_DIVISOR * BAT_CAL, 0.0f, 20.0f);
}

void battery_get(float* v, int* pct) {
  portENTER_CRITICAL(&s_mux);
  *v = s_batVoltage; *pct = s_batPercent;
  portEXIT_CRITICAL(&s_mux);
}

void battery_send() {
  float v; int p;
  battery_get(&v, &p);
  ble_sendf("$BAT:%.2f:%d\n", v, p);
}

static void update_battery() {
  float v = read_battery_volts();
  int pct = volt_to_soc_pb(v);
  float oldV; int oldP;
  battery_get(&oldV, &oldP);
  if (fabsf(v - oldV) >= 0.05f || pct != oldP) {
    portENTER_CRITICAL(&s_mux);
    s_batVoltage = v; s_batPercent = pct;
    portEXIT_CRITICAL(&s_mux);
    if (ble_connected()) battery_send();
  }
}

void telemetry_init() {
  adc_oneshot_unit_init_cfg_t u = {};
  u.unit_id = ADC_UNIT_1;
  ESP_ERROR_CHECK(adc_oneshot_new_unit(&u, &s_adc));
  adc_oneshot_chan_cfg_t c = {};
  c.atten    = ADC_ATTEN_DB_12;      // equivalente ao ADC_11db (faixa ~0-3.3V)
  c.bitwidth = ADC_BITWIDTH_12;
  ESP_ERROR_CHECK(adc_oneshot_config_channel(s_adc, BAT_CH, &c));

  float v = read_battery_volts();
  s_batVoltage = v;
  s_batPercent = volt_to_soc_pb(v);
  ESP_LOGI(TAG, "Bateria %.2f V (%d%%)", s_batVoltage, s_batPercent);
}

static void send_telemetry() {
  GpsData g = gps_get();
  ControlSnapshot s = control_snapshot();
  bool gpsOk = g.valid && g.ageMs() < 3000;
  char buf[128];
  int n = snprintf(buf, sizeof(buf), "$%.7f,%.7f,%.1f,%.2f,%.2f,%.1f,%d,%d,%d,%d,%lu\n",
                   gpsOk ? g.lat : 0.0,
                   gpsOk ? g.lon : 0.0,
                   s.heading,
                   gpsOk ? g.speedKmh : 0.0f,
                   s.anchorMode ? s.distancia : 0.0f,
                   s.anchorMode ? s.bearingFiltered : 0.0f,
                   s.anchorMode ? 1 : 0,
                   s.pwmComHeading,
                   s.northMode ? 1 : 0,
                   s.motorLigado ? 1 : 0,
                   (unsigned long)g.sats);
  if (n > 0) ble_send(buf, (size_t)n);

  // Estado da ancora (para o app):
  // $ANS:<dist_m>:<vel_m/s>:<forca_pwm>:<dir_forca>:<hdop>:<sem_gps>:<helice>
  AnchorStatus a = anchor_status();
  if (a.active) {
    n = snprintf(buf, sizeof(buf), "$ANS:%.2f:%.2f:%.0f:%.0f:%.1f:%d:%d\n",
                 a.distance, a.speed, a.holdPwm, a.holdDir, a.hdop,
                 a.gpsLost ? 1 : 0, a.throttle);
    if (n > 0) ble_send(buf, (size_t)n);
  }
}

static void telemetry_task(void*) {
  TickType_t last = xTaskGetTickCount();
  uint32_t lastBat = millis();
  for (;;) {
    vTaskDelayUntil(&last, pdMS_TO_TICKS(500));
    if (ble_connected()) send_telemetry();
    if (millis() - lastBat >= BAT_READ_INTERVAL) {
      lastBat = millis();
      update_battery();
    }
  }
}

void telemetry_start() {
  xTaskCreatePinnedToCore(telemetry_task, "telemetry", STACK_TELEMETRY, nullptr,
                          PRIO_TELEMETRY, nullptr, CORE_COMM);
}
