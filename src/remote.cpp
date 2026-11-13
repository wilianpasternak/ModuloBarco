#include "remote.h"

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "commands.h"
#include "config.h"
#include "nrf24.h"
#include "util.h"

static const char* TAG = "remote";
static const uint8_t ADDRESS[5] = { '0', '0', '0', '0', '1' };   // "00001"

static void remote_task(void*) {
  bool ok = nrf24_init(ADDRESS, NRF_PAYLOAD_SIZE);
  uint32_t lastRetry = millis(), lastCheck = millis();
  TickType_t last = xTaskGetTickCount();
  for (;;) {
    vTaskDelayUntil(&last, pdMS_TO_TICKS(REMOTE_PERIOD_MS));
    uint32_t now = millis();

    if (!ok) {
      if (now - lastRetry >= 5000) {
        lastRetry = now;
        ok = nrf24_init(ADDRESS, NRF_PAYLOAD_SIZE);
      }
      continue;
    }
    if (now - lastCheck >= 2000) {          // radio desconectou/resetou?
      lastCheck = now;
      if (!nrf24_chip_connected()) {
        ESP_LOGW(TAG, "NRF24 nao responde — reinicializando");
        ok = false;
        lastRetry = now - 5000;
        continue;
      }
    }

    // FIFO de RX tem 3 posicoes; o limite evita loop se o chip sumir no meio
    for (int i = 0; i < 3 && nrf24_available(); i++) {
      Command c = {};
      c.type = CmdType::NrfPacket;
      nrf24_read(c.data, sizeof(c.data));
      ESP_LOGD(TAG, "pacote: %.18s", (const char*)c.data);
      commands_post(c);
    }
  }
}

void remote_start() {
  xTaskCreatePinnedToCore(remote_task, "remote", STACK_REMOTE, nullptr,
                          PRIO_REMOTE, nullptr, CORE_COMM);
}
