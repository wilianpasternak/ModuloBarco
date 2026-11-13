#include "gps.h"

#include "TinyGPS++.h"
#include "driver/uart.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "config.h"
#include "util.h"

static const char* TAG = "gps";
static constexpr uart_port_t GPS_UART = UART_NUM_2;
static constexpr int RX_BUF = 2048;

static TinyGPSPlus  s_gps;
static GpsData      s_data;
static portMUX_TYPE s_mux = portMUX_INITIALIZER_UNLOCKED;

uint32_t GpsData::ageMs() const {
  return valid ? millis() - fixMs : UINT32_MAX;
}

GpsData gps_get() {
  portENTER_CRITICAL(&s_mux);
  GpsData d = s_data;
  portEXIT_CRITICAL(&s_mux);
  return d;
}

// UBX-CFG-PRT: muda baud do modulo para 38400 (enviado em 9600)
static const uint8_t UBX_CFG_PRT_38400[] = {
  0xB5,0x62, 0x06,0x00, 0x14,0x00,
  0x01,0x00,0x00,0x00,              // portID=1 (UART1), reserved, txReady
  0xC0,0x08,0x00,0x00,              // mode: 8N1
  0x00,0x96,0x00,0x00,              // baudRate: 38400 LE
  0x07,0x00,                        // inProtoMask: UBX+NMEA+RTCM
  0x03,0x00,                        // outProtoMask: UBX+NMEA
  0x00,0x00,0x00,0x00,              // flags, reserved5
  0x83,0x90                         // checksum
};
// UBX-CFG-RATE: 200ms = 5Hz (enviado em 38400)
static const uint8_t UBX_RATE_5HZ[] = {
  0xB5,0x62, 0x06,0x08, 0x06,0x00,
  0xC8,0x00,                        // measRate: 200ms
  0x01,0x00,                        // navRate: 1
  0x01,0x00,                        // timeRef: GPS
  0xDE,0x6A                         // checksum
};
// UBX-CFG-CFG: salva tudo na flash do modulo GPS
static const uint8_t UBX_SAVE[] = {
  0xB5,0x62, 0x06,0x09, 0x0D,0x00,
  0x00,0x00,0x00,0x00,              // clearMask: nada
  0xFF,0xFF,0x00,0x00,              // saveMask: tudo
  0x00,0x00,0x00,0x00,              // loadMask: nada
  0x17,                             // deviceMask: BBR+Flash+EEPROM
  0x31,0xBF                         // checksum
};

static void uart_send(const uint8_t* d, size_t n) {
  uart_write_bytes(GPS_UART, (const char*)d, n);
  uart_wait_tx_done(GPS_UART, pdMS_TO_TICKS(200));
}

// Sempre reconfigura a partir de 9600 em todo boot.
// Se o GPS ja estiver em 38400, o CFG-PRT em 9600 chega como lixo e e
// ignorado. Se voltou ao padrao de fabrica (9600), recebe o CFG-PRT e
// muda para 38400. Em ambos os casos a UART segue em 38400.
static void configure_module() {
  uart_set_baudrate(GPS_UART, 9600);
  delay_ms(500);
  uart_send(UBX_CFG_PRT_38400, sizeof(UBX_CFG_PRT_38400));
  delay_ms(200);
  uart_set_baudrate(GPS_UART, 38400);
  delay_ms(100);
  uart_send(UBX_RATE_5HZ, sizeof(UBX_RATE_5HZ));
  delay_ms(100);
  uart_send(UBX_SAVE, sizeof(UBX_SAVE));
  delay_ms(600);                     // gravacao na EEPROM/BBR do modulo
  uart_flush_input(GPS_UART);
  ESP_LOGI(TAG, "Configurado 38400 / 5Hz");
}

static void gps_task(void*) {
  configure_module();

  uint8_t buf[256];
  uint32_t lastLog = millis(), epochs = 0, lastTime = UINT32_MAX;
  for (;;) {
    // Dorme ate chegar o primeiro byte; depois le tudo que ja esta no buffer
    int n = uart_read_bytes(GPS_UART, buf, 1, pdMS_TO_TICKS(100));
    if (n > 0) {
      size_t avail = 0;
      uart_get_buffered_data_len(GPS_UART, &avail);
      if (avail > sizeof(buf) - 1) avail = sizeof(buf) - 1;
      if (avail) {
        int m = uart_read_bytes(GPS_UART, buf + 1, avail, 0);
        if (m > 0) n += m;
      }
    }
    bool newLoc = false;
    for (int i = 0; i < n; i++) {
      if (s_gps.encode((char)buf[i])) {
        if (s_gps.location.isUpdated()) newLoc = true;
        if (s_gps.time.isUpdated() && s_gps.time.value() != lastTime) {
          lastTime = s_gps.time.value();
          epochs++;
        }
      }
    }
    if (newLoc || n > 0) {
      GpsData d;
      d.valid    = s_gps.location.isValid();
      d.lat      = s_gps.location.lat();
      d.lon      = s_gps.location.lng();
      d.speedKmh = (float)s_gps.speed.kmph();
      d.speedMps = (float)s_gps.speed.mps();
      d.courseValid = s_gps.course.isValid();
      d.courseDeg = (float)s_gps.course.deg();
      d.hdop     = s_gps.hdop.isValid() ? (float)s_gps.hdop.hdop() : 99.0f;
      d.sats     = s_gps.satellites.value();
      portENTER_CRITICAL(&s_mux);
      d.fixMs = newLoc ? millis() : s_data.fixMs;
      d.seq   = s_data.seq + (newLoc ? 1 : 0);
      s_data  = d;
      portEXIT_CRITICAL(&s_mux);
    }

    uint32_t now = millis();
    if (now - lastLog >= 4000) {
      ESP_LOGD(TAG, "rate=%.2fHz fix=%s sats=%lu chars=%lu",
               epochs / ((now - lastLog) / 1000.0f),
               s_gps.location.isValid() ? "SIM" : "NAO",
               (unsigned long)s_gps.satellites.value(),
               (unsigned long)s_gps.charsProcessed());
      epochs = 0;
      lastLog = now;
    }
  }
}

void gps_start() {
  uart_config_t c = {};
  c.baud_rate  = 9600;
  c.data_bits  = UART_DATA_8_BITS;
  c.parity     = UART_PARITY_DISABLE;
  c.stop_bits  = UART_STOP_BITS_1;
  c.flow_ctrl  = UART_HW_FLOWCTRL_DISABLE;
  c.source_clk = UART_SCLK_DEFAULT;
  ESP_ERROR_CHECK(uart_driver_install(GPS_UART, RX_BUF, 0, 0, nullptr, 0));
  ESP_ERROR_CHECK(uart_param_config(GPS_UART, &c));
  ESP_ERROR_CHECK(uart_set_pin(GPS_UART, PIN_GPS_TX, PIN_GPS_RX,
                               UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE));
  xTaskCreatePinnedToCore(gps_task, "gps", STACK_GPS, nullptr,
                          PRIO_GPS, nullptr, CORE_CTRL);
}
