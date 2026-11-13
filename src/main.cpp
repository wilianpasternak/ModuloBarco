// ================================================================
//  PescaPlus — Modulo Barco — firmware ESP-IDF
//
//  Nucleo 0: NimBLE, remote (NRF24), OTA, telemetria, buzzer, NVS
//  Nucleo 1: control (50 Hz), compass (20 Hz), gps (UART)
// ================================================================
#define FIRMWARE_VERSION "2.0.0"

#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "ble.h"
#include "buzzer.h"
#include "commands.h"
#include "compass.h"
#include "config.h"
#include "control.h"
#include "gps.h"
#include "motors.h"
#include "ota.h"
#include "remote.h"
#include "settings.h"
#include "telemetry.h"
#include "util.h"

static const char* TAG = "main";

const char* firmware_version() { return FIRMWARE_VERSION; }

// Tempo que o firmware precisa rodar sem travar para se confirmar.
// Se reiniciar antes (crash, watchdog), o bootloader volta para a
// versao anterior na proxima inicializacao.
static constexpr uint32_t SELFTEST_MS = 10000;

static void log_boot_info() {
  const esp_partition_t* p = esp_ota_get_running_partition();
  esp_ota_img_states_t st = ESP_OTA_IMG_UNDEFINED;
  esp_ota_get_state_partition(p, &st);
  ESP_LOGI(TAG, "========================================");
  ESP_LOGI(TAG, "  %s — firmware %s", DEVICE_NAME, FIRMWARE_VERSION);
  ESP_LOGI(TAG, "  Particao: %s  estado: %s  reset: %d", p ? p->label : "?",
           st == ESP_OTA_IMG_PENDING_VERIFY ? "EM TESTE" : "ok", (int)esp_reset_reason());
  ESP_LOGI(TAG, "========================================");
}

extern "C" void app_main() {
  // 1) Failsafe: reles desligados e PWM em 0 antes de qualquer coisa
  motors_init();
  log_boot_info();

  // 2) Configuracoes persistidas
  Settings cfg;
  settings_init(cfg);
  settings_start();

  // 3) Infra
  buzzer_init(cfg.buzzerOn);
  commands_init();
  telemetry_init();

  // 4) Sensores (nucleo 1)
  CompassCal cal;
  if (cfg.compCalib) {
    cal.xOff = cfg.compXoff;   cal.yOff = cfg.compYoff;
    cal.xScale = cfg.compXscl; cal.yScale = cfg.compYscl;
    cal.ref    = cfg.compRef;
  }
  compass_init(cal);
  compass_start();
  gps_start();

  // 5) Controle (nucleo 1)
  control_start(cfg);

  // 6) Comunicacao (nucleo 0)
  remote_start();
  ota_init();
  ble_init();
  telemetry_start();

  ESP_LOGI(TAG, "Pronto.");

  // 7) Autoteste: confirma a imagem se o controle esta rodando ha SELFTEST_MS
  delay_ms(SELFTEST_MS);
  uint32_t cycles = control_cycles();
  uint32_t expected = SELFTEST_MS / CONTROL_PERIOD_MS / 2;   // ao menos metade dos ciclos
  if (cycles >= expected) {
    ota_confirm_running_image();
  } else {
    ESP_LOGE(TAG, "Autoteste falhou (%lu ciclos de controle) — rollback", (unsigned long)cycles);
    esp_ota_mark_app_invalid_rollback_and_reboot();
  }
  // app_main retorna: a task principal e liberada
}
