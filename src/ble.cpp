#include "ble.h"

#include <atomic>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <NimBLEDevice.h>
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "commands.h"
#include "config.h"
#include "ota.h"

static const char* TAG = "ble";

static NimBLECharacteristic* s_chr = nullptr;
static NimBLECharacteristic* s_ota = nullptr;
static std::atomic<bool>     s_connected{false};
static SemaphoreHandle_t     s_txMutex = nullptr;

// Buffer de linha (comandos chegam terminados em '\n')
static char   s_line[64];
static size_t s_lineLen = 0;
static bool   s_lineOverflow = false;

static void post_event(CmdType t) {
  Command c = {};
  c.type = t;
  commands_post(c, pdMS_TO_TICKS(50));
}

class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer*, NimBLEConnInfo& info) override {
    s_lineLen = 0; s_lineOverflow = false;
    s_connected = true;
    ESP_LOGI(TAG, "Conectado: %s", info.getAddress().toString().c_str());
    post_event(CmdType::BleConnected);
  }
  void onDisconnect(NimBLEServer*, NimBLEConnInfo&, int reason) override {
    s_connected = false;
    ESP_LOGI(TAG, "Desconectado (motivo 0x%02x) — advertising", reason);
    ota_on_disconnect();
    post_event(CmdType::BleDisconnected);
  }
  void onMTUChange(uint16_t mtu, NimBLEConnInfo&) override {
    ESP_LOGI(TAG, "MTU %u", mtu);
  }
};

class CmdCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c, NimBLEConnInfo&) override {
    NimBLEAttValue v = c->getValue();
    const uint8_t* d = v.data();
    for (size_t i = 0; i < v.length(); i++) {
      char ch = (char)d[i];
      if (ch == '\n') {
        if (!s_lineOverflow) commands_post(commands_parse(s_line, s_lineLen), pdMS_TO_TICKS(50));
        s_lineLen = 0; s_lineOverflow = false;
      } else if (ch != '\r') {
        if (s_lineLen < sizeof(s_line) - 1) s_line[s_lineLen++] = ch;
        else s_lineOverflow = true;      // linha longa demais: descarta
      }
    }
  }
};

class OtaCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c, NimBLEConnInfo&) override {
    NimBLEAttValue v = c->getValue();
    ota_on_write(v.data(), v.length());
  }
};

void ble_init() {
  s_txMutex = xSemaphoreCreateMutex();

  NimBLEDevice::init(DEVICE_NAME);
  NimBLEDevice::setMTU(512);
  NimBLEDevice::setPower(9);   // dBm (maximo do ESP32)

  NimBLEServer* server = NimBLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());
  server->advertiseOnDisconnect(true);

  NimBLEService* svc = server->createService(BLE_SVC_UUID);
  s_chr = svc->createCharacteristic(BLE_CHR_UUID,
      NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::WRITE |
      NIMBLE_PROPERTY::NOTIFY | NIMBLE_PROPERTY::WRITE_NR);
  s_chr->setCallbacks(new CmdCallbacks());

  s_ota = svc->createCharacteristic(BLE_OTA_UUID,
      NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR | NIMBLE_PROPERTY::NOTIFY);
  s_ota->setCallbacks(new OtaCallbacks());

  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->setName(DEVICE_NAME);
  adv->addServiceUUID(NimBLEUUID((uint16_t)0xFFE0));   // forma curta: cabe no pacote com o nome
  adv->enableScanResponse(true);
  adv->start();
  ESP_LOGI(TAG, "Advertising '%s'", DEVICE_NAME);
}

bool ble_connected() { return s_connected; }

static void notify(NimBLECharacteristic* chr, const char* s, size_t len) {
  if (!s_connected || !chr || len == 0) return;
  if (xSemaphoreTake(s_txMutex, pdMS_TO_TICKS(100)) != pdTRUE) return;
  chr->setValue((const uint8_t*)s, len);
  chr->notify();
  xSemaphoreGive(s_txMutex);
}

void ble_send(const char* s, size_t len) { notify(s_chr, s, len); }
void ble_send(const char* s)             { notify(s_chr, s, strlen(s)); }
void ble_ota_send(const char* s)         { notify(s_ota, s, strlen(s)); }

void ble_sendf(const char* fmt, ...) {
  char buf[128];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  if (n > 0) ble_send(buf, n < (int)sizeof(buf) ? (size_t)n : sizeof(buf) - 1);
}
