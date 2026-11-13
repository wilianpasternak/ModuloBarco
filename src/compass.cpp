#include "compass.h"

#include <atomic>
#include <math.h>
#include "driver/i2c_master.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "config.h"
#include "heading_filter.h"
#include "util.h"

static const char* TAG = "compass";

static constexpr uint8_t  HMC_ADDR    = 0x1E;
static constexpr int      I2C_TIMEOUT = 100;   // ms (Wire.setTimeout(100))

static i2c_master_bus_handle_t s_bus = nullptr;
static i2c_master_dev_handle_t s_dev = nullptr;
static bool s_present = false;

static std::atomic<float> s_heading{0.0f};
static std::atomic<float> s_rate{0.0f};      // graus/s (+ = direita)
static std::atomic<bool>  s_fieldFault{false};
static std::atomic<float> s_fieldRatio{1.0f};
static constexpr float FIELD_TOL     = 0.30f;   // +-30% da referencia
static constexpr float FIELD_OK_TOL  = 0.20f;   // volta ao normal dentro de +-20%
static constexpr int   FIELD_HOLD_N  = 150;     // 3 s a 50 Hz
static float s_ema = 1.0f;                      // so a compass_task escreve
static int   s_badN = 0, s_goodN = 0;
static portMUX_TYPE s_mux = portMUX_INITIALIZER_UNLOCKED;
static CompassCal s_cal;

static bool  s_calib = false;
static bool  s_verify = false;
static CompassVerify s_ver;
static float s_verLast = -1.0f;
static int   s_calibSamples = 0;
static float s_minX, s_maxX, s_minY, s_maxY;

// ================= FILTRO DO RUMO (angulo + velocidade de giro) =================
static HeadingFilter s_kf;
static std::atomic<bool> s_kfReset{false};

// Leitura direta dos registradores de dados (X, Z, Y)
static bool hmc_read_raw(float& fx, float& fy) {
  if (!s_present) return false;
  uint8_t reg = 0x03, b[6];
  if (i2c_master_transmit_receive(s_dev, &reg, 1, b, 6, I2C_TIMEOUT) != ESP_OK) return false;
  int16_t rx = (int16_t)((b[0] << 8) | b[1]);
  int16_t ry = (int16_t)((b[4] << 8) | b[5]);   // b[2..3] = Z ignorado
  fx = rx * 0.92f;
  fy = ry * 0.92f;
  return true;
}

static bool hmc_write(uint8_t reg, uint8_t val) {
  uint8_t b[2] = { reg, val };
  return i2c_master_transmit(s_dev, b, 2, I2C_TIMEOUT) == ESP_OK;
}

bool compass_init(const CompassCal& cal) {
  s_cal = cal;

  i2c_master_bus_config_t bc = {};
  bc.i2c_port   = I2C_NUM_0;
  bc.sda_io_num = PIN_I2C_SDA;
  bc.scl_io_num = PIN_I2C_SCL;
  bc.clk_source = I2C_CLK_SRC_DEFAULT;
  bc.glitch_ignore_cnt = 7;
  bc.flags.enable_internal_pullup = true;
  ESP_ERROR_CHECK(i2c_new_master_bus(&bc, &s_bus));

  i2c_device_config_t dc = {};
  dc.dev_addr_length = I2C_ADDR_BIT_LEN_7;
  dc.device_address  = HMC_ADDR;
  dc.scl_speed_hz    = 50000;   // 50 kHz — mais tolerante a ruido do motor/ESC
  ESP_ERROR_CHECK(i2c_master_bus_add_device(s_bus, &dc, &s_dev));

  // Falhas transitorias de I2C sao tratadas aqui; evita log a cada leitura
  esp_log_level_set("i2c.master", ESP_LOG_NONE);

  s_present = (i2c_master_probe(s_bus, HMC_ADDR, I2C_TIMEOUT) == ESP_OK);
  if (!s_present) {
    ESP_LOGE(TAG, "HMC5883L NAO ENCONTRADO (SDA=%d SCL=%d)", PIN_I2C_SDA, PIN_I2C_SCL);
    return false;
  }
  hmc_write(0x00, 0x78);   // CRA: 8 amostras, 75 Hz (lido a 50 Hz)
  hmc_write(0x01, 0x20);   // CRB: ganho 1.3 Ga
  hmc_write(0x02, 0x00);   // modo continuo
  ESP_LOGI(TAG, "HMC5883L OK — offset X=%.2f Y=%.2f escala X=%.3f Y=%.3f",
           cal.xOff, cal.yOff, cal.xScale, cal.yScale);
  return true;
}

static void compass_task(void*) {
  TickType_t last = xTaskGetTickCount();
  int fails = 0;
  for (;;) {
    vTaskDelayUntil(&last, pdMS_TO_TICKS(COMPASS_PERIOD_MS));
    const float dt = COMPASS_PERIOD_MS / 1000.0f;
    if (s_kfReset.exchange(false)) s_kf.reset();
    float mx, my;
    if (hmc_read_raw(mx, my)) {
      fails = 0;
      portENTER_CRITICAL(&s_mux);
      CompassCal c = s_cal;
      if (s_calib) {
        if (s_calibSamples == 0) { s_minX = s_maxX = mx; s_minY = s_maxY = my; }
        s_minX = fminf(s_minX, mx); s_maxX = fmaxf(s_maxX, mx);
        s_minY = fminf(s_minY, my); s_maxY = fmaxf(s_maxY, my);
        s_calibSamples++;
      }
      portEXIT_CRITICAL(&s_mux);
      // Centro (hard-iron) + escala por eixo: transforma a elipse em circulo
      float cx = (mx - c.xOff) * c.xScale, cy = (my - c.yOff) * c.yScale;
      float h = atan2f(cy, cx) * 180.0f / (float)M_PI;
      if (h < 0) h += 360.0f;
      // Monitor da calibracao em uso (so com referencia conhecida)
      if (c.ref > 0) {
        float ratio = sqrtf(cx * cx + cy * cy) / c.ref;
        s_ema += 0.05f * (ratio - s_ema);
        float ema = s_ema;                 // suaviza o ruido (~0,4 s)
        s_fieldRatio.store(ema);
        bool bad = fabsf(ema - 1.0f) > FIELD_TOL;
        bool good = fabsf(ema - 1.0f) < FIELD_OK_TOL;
        s_badN  = bad  ? s_badN + 1  : 0;
        s_goodN = good ? s_goodN + 1 : 0;
        if (!s_fieldFault.load() && s_badN >= FIELD_HOLD_N) {
          s_fieldFault.store(true);
          ESP_LOGW(TAG, "Campo magnetico fora do esperado (%.2fx) — calibracao invalida", ema);
        } else if (s_fieldFault.load() && s_goodN >= FIELD_HOLD_N) {
          s_fieldFault.store(false);
          ESP_LOGI(TAG, "Campo magnetico normal de novo (%.2fx)", ema);
        }
      }
      if (s_verify) {
        float field = sqrtf(cx * cx + cy * cy);
        portENTER_CRITICAL(&s_mux);
        s_ver.sectors |= (uint16_t)(1u << ((int)(h / 30.0f) % 12));
        if (s_verLast >= 0) {
          float d = wrap180(h - s_verLast);
          s_ver.rotation += d;
          if (fabsf(d) > s_ver.maxJump) s_ver.maxJump = fabsf(d);
        }
        if (s_ver.samples == 0) { s_ver.fieldMin = s_ver.fieldMax = field; }
        s_ver.fieldMin = fminf(s_ver.fieldMin, field);
        s_ver.fieldMax = fmaxf(s_ver.fieldMax, field);
        s_ver.samples++;
        s_verLast = h;
        portEXIT_CRITICAL(&s_mux);
      }
      s_kf.update(h, dt);
    } else {
      s_kf.predict(dt);                     // falha: so propaga
      if (s_present && ++fails == 10) {
        ESP_LOGW(TAG, "Falhas de leitura I2C — resetando barramento");
        i2c_master_bus_reset(s_bus);
        fails = 0;
      }
    }
    s_heading.store(s_kf.angle);
    s_rate.store(s_kf.rate);
  }
}

void compass_start() {
  xTaskCreatePinnedToCore(compass_task, "compass", STACK_COMPASS, nullptr,
                          PRIO_COMPASS, nullptr, CORE_CTRL);
}

float compass_heading() { return s_heading.load(); }
float compass_rate()    { return s_rate.load(); }
bool  compass_present() { return s_present; }
bool  compass_field_fault() { return s_fieldFault.load(); }
float compass_field_ratio() { return s_fieldRatio.load(); }

void compass_reset_filter() { s_kfReset = true; }

void compass_set_calibration(const CompassCal& cal) {
  portENTER_CRITICAL(&s_mux);
  s_cal = cal;
  s_ema = 1.0f; s_badN = 0; s_goodN = 0;
  portEXIT_CRITICAL(&s_mux);
  s_fieldFault.store(false);
  s_fieldRatio.store(1.0f);
}

CompassCal compass_get_calibration() {
  portENTER_CRITICAL(&s_mux);
  CompassCal c = s_cal;
  portEXIT_CRITICAL(&s_mux);
  return c;
}

void compass_verify_begin() {
  portENTER_CRITICAL(&s_mux);
  s_ver = CompassVerify();
  s_verLast = -1.0f;
  s_verify = true;
  portEXIT_CRITICAL(&s_mux);
}

CompassVerify compass_verify_get() {
  portENTER_CRITICAL(&s_mux);
  CompassVerify v = s_ver;
  portEXIT_CRITICAL(&s_mux);
  return v;
}

void compass_verify_end() {
  portENTER_CRITICAL(&s_mux);
  s_verify = false;
  portEXIT_CRITICAL(&s_mux);
}

void compass_calib_begin() {
  portENTER_CRITICAL(&s_mux);
  s_calibSamples = 0;
  s_calib = true;
  portEXIT_CRITICAL(&s_mux);
}

bool compass_calib_end(CompassCal* out) {
  portENTER_CRITICAL(&s_mux);
  s_calib = false;
  int   n  = s_calibSamples;
  float rx = (s_maxX - s_minX) / 2.0f;
  float ry = (s_maxY - s_minY) / 2.0f;
  float cx = (s_maxX + s_minX) / 2.0f;
  float cy = (s_maxY + s_minY) / 2.0f;
  portEXIT_CRITICAL(&s_mux);
  // Precisa de amostras e de amplitude real nos dois eixos (o campo da Terra
  // da ~200-600 nesta escala; abaixo de 30 o motor nao girou de verdade)
  if (n < 10 || rx < 30.0f || ry < 30.0f) return false;
  out->xOff = cx;
  out->yOff = cy;
  float avg = (rx + ry) / 2.0f;
  out->xScale = avg / rx;
  out->yScale = avg / ry;
  out->ref    = avg;          // raio do circulo depois da correcao
  return true;
}
