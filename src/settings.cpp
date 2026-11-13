#include "settings.h"

#include <string.h>
#include <stdio.h>
#include "esp_log.h"
#include "nvs_flash.h"
#include "nvs.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "util.h"

static const char* TAG = "settings";

enum class ValType : uint8_t { I32, U32, Bool, Float };

struct PendingWrite {
  char    key[NVS_KEY_NAME_MAX_SIZE];
  ValType type;
  bool    immediate;
  union { int32_t i; uint32_t u; float f; } v;
};

static QueueHandle_t s_queue = nullptr;
static constexpr int    MAX_PENDING  = 24;
static constexpr uint32_t DEBOUNCE_MS = 1000;

// ---------------- leitura ----------------
static int32_t get_i32(nvs_handle_t h, const char* k, int32_t def) {
  int32_t v; return nvs_get_i32(h, k, &v) == ESP_OK ? v : def;
}
static uint32_t get_u32(nvs_handle_t h, const char* k, uint32_t def) {
  uint32_t v; return nvs_get_u32(h, k, &v) == ESP_OK ? v : def;
}
static bool get_bool(nvs_handle_t h, const char* k, bool def) {
  uint8_t v; return nvs_get_u8(h, k, &v) == ESP_OK ? (v != 0) : def;
}
static float get_float(nvs_handle_t h, const char* k, float def) {
  float v; size_t len = sizeof(v);
  return (nvs_get_blob(h, k, &v, &len) == ESP_OK && len == sizeof(v)) ? v : def;
}

void settings_init(Settings& s) {
  esp_err_t err = nvs_flash_init();
  if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
    ESP_LOGW(TAG, "NVS invalida (%s) — apagando", esp_err_to_name(err));
    ESP_ERROR_CHECK(nvs_flash_erase());
    err = nvs_flash_init();
  }
  ESP_ERROR_CHECK(err);

  nvs_handle_t h;
  if (nvs_open(NVS_NAMESPACE, NVS_READONLY, &h) != ESP_OK) {
    ESP_LOGI(TAG, "Sem configuracoes salvas — usando padroes");
    return;
  }
  s.pwmHelMin    = get_i32(h, "pwmHelMin",    s.pwmHelMin);
  s.pwmMotorOff  = get_i32(h, "pwmMotorOff",  s.pwmMotorOff);
  s.hdgOff       = get_i32(h, "hdgOff",       s.hdgOff);
  s.calibTimeSeg = get_i32(h, "calibTimeSeg", s.calibTimeSeg);
  s.calibPwmGiro = get_i32(h, "calibPwmGiro", s.calibPwmGiro);
  s.usoPwmGiro   = get_i32(h, "usoPwmGiro",   s.usoPwmGiro);
  s.aceInc       = get_i32(h, "aceInc",       s.aceInc);
  s.buzzerOn     = get_bool(h, "buzzerOn",    s.buzzerOn);
  s.compCalib    = get_bool(h, "compCalib",   s.compCalib);
  if (s.compCalib) {
    s.compXoff = get_float(h, "compXoff", 0.0f);
    s.compYoff = get_float(h, "compYoff", 0.0f);
    s.compXscl = get_float(h, "compXscl", 1.0f);
    s.compYscl = get_float(h, "compYscl", 1.0f);
    s.compRef  = get_float(h, "compRef", 0.0f);
  }
  s.ancKp10 = get_i32(h, "ancKp", s.ancKp10);
  s.ancKi10 = get_i32(h, "ancKi", s.ancKi10);
  s.ancKd10 = get_i32(h, "ancKd", s.ancKd10);
  for (int i = 0; i < MAX_CONTROLES; i++) {
    char key[8]; snprintf(key, sizeof(key), "ctrl%d", i);
    s.ctrl[i] = get_u32(h, key, 0);
  }
  nvs_close(h);
  ESP_LOGI(TAG, "pwmHelMin=%ld pwmMotorOff=%ld hdgOff=%ld buzzer=%d bussola=%s",
           (long)s.pwmHelMin, (long)s.pwmMotorOff, (long)s.hdgOff, s.buzzerOn,
           s.compCalib ? "calibrada" : "SEM calibracao");
}

// ---------------- escrita ----------------
static void write_one(nvs_handle_t h, const PendingWrite& w) {
  esp_err_t err = ESP_OK;
  switch (w.type) {
    case ValType::I32:   err = nvs_set_i32(h, w.key, w.v.i); break;
    case ValType::U32:   err = nvs_set_u32(h, w.key, w.v.u); break;
    case ValType::Bool:  err = nvs_set_u8(h, w.key, w.v.u ? 1 : 0); break;
    case ValType::Float: err = nvs_set_blob(h, w.key, &w.v.f, sizeof(float)); break;
  }
  if (err != ESP_OK) ESP_LOGE(TAG, "Falha gravando %s: %s", w.key, esp_err_to_name(err));
}

static void flush(PendingWrite* pend, int& n) {
  if (n == 0) return;
  nvs_handle_t h;
  esp_err_t err = nvs_open(NVS_NAMESPACE, NVS_READWRITE, &h);
  if (err != ESP_OK) { ESP_LOGE(TAG, "nvs_open: %s", esp_err_to_name(err)); n = 0; return; }
  for (int i = 0; i < n; i++) write_one(h, pend[i]);
  err = nvs_commit(h);
  if (err != ESP_OK) ESP_LOGE(TAG, "nvs_commit: %s", esp_err_to_name(err));
  nvs_close(h);
  ESP_LOGD(TAG, "%d chave(s) gravada(s)", n);
  n = 0;
}

static void settings_task(void*) {
  PendingWrite pend[MAX_PENDING];
  int n = 0;
  uint32_t deadline = 0;
  for (;;) {
    TickType_t wait = portMAX_DELAY;
    if (n > 0) {
      int32_t left = (int32_t)(deadline - millis());
      wait = left > 0 ? pdMS_TO_TICKS(left) : 0;
    }
    PendingWrite w;
    if (xQueueReceive(s_queue, &w, wait) == pdTRUE) {
      // Coalesce: a mesma chave so guarda o valor mais recente
      int idx = -1;
      for (int i = 0; i < n; i++) if (strcmp(pend[i].key, w.key) == 0) { idx = i; break; }
      if (idx < 0) {
        if (n == MAX_PENDING) flush(pend, n);
        idx = n++;
      }
      pend[idx] = w;
      deadline = millis() + DEBOUNCE_MS;
      if (w.immediate) flush(pend, n);
    } else {
      flush(pend, n);
    }
  }
}

void settings_start() {
  s_queue = xQueueCreate(16, sizeof(PendingWrite));
  xTaskCreatePinnedToCore(settings_task, "settings", STACK_SETTINGS, nullptr,
                          PRIO_SETTINGS, nullptr, CORE_COMM);
}

static void post(const char* key, ValType t, uint32_t raw, bool immediate) {
  if (!s_queue) return;
  PendingWrite w = {};
  strlcpy(w.key, key, sizeof(w.key));
  w.type = t;
  w.immediate = immediate;
  w.v.u = raw;
  if (xQueueSend(s_queue, &w, pdMS_TO_TICKS(100)) != pdTRUE)
    ESP_LOGE(TAG, "Fila cheia — %s nao gravado", key);
}

void settings_set_i32(const char* k, int32_t v, bool imm)  { post(k, ValType::I32, (uint32_t)v, imm); }
void settings_set_u32(const char* k, uint32_t v, bool imm) { post(k, ValType::U32, v, imm); }
void settings_set_bool(const char* k, bool v, bool imm)    { post(k, ValType::Bool, v ? 1u : 0u, imm); }
void settings_set_float(const char* k, float v, bool imm) {
  uint32_t raw; memcpy(&raw, &v, sizeof(raw));
  post(k, ValType::Float, raw, imm);
}
