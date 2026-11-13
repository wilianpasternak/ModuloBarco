#include "nrf24.h"

#include <string.h>
#include "driver/gpio.h"
#include "driver/spi_master.h"
#include "esp_log.h"
#include "config.h"
#include "util.h"

static const char* TAG = "nrf24";

// Registradores
enum : uint8_t {
  REG_CONFIG = 0x00, REG_EN_AA = 0x01, REG_EN_RXADDR = 0x02, REG_SETUP_AW = 0x03,
  REG_SETUP_RETR = 0x04, REG_RF_CH = 0x05, REG_RF_SETUP = 0x06, REG_STATUS = 0x07,
  REG_RX_ADDR_P1 = 0x0B, REG_RX_PW_P0 = 0x11, REG_FIFO_STATUS = 0x17,
  REG_DYNPD = 0x1C, REG_FEATURE = 0x1D,
};
// Comandos
enum : uint8_t {
  CMD_R_REGISTER = 0x00, CMD_W_REGISTER = 0x20, CMD_R_RX_PAYLOAD = 0x61,
  CMD_FLUSH_TX = 0xE1, CMD_FLUSH_RX = 0xE2,
};
// Bits
static constexpr uint8_t CONFIG_BASE = 0x7C;   // MASK_RX_DR|MASK_TX_DS|MASK_MAX_RT|EN_CRC|CRCO
static constexpr uint8_t PWR_UP  = 0x02;
static constexpr uint8_t PRIM_RX = 0x01;
static constexpr uint8_t RX_DR   = 0x40;
static constexpr uint8_t IRQ_ALL = 0x70;

static spi_device_handle_t s_spi = nullptr;
static uint8_t s_payload = 32;

static void ce(bool high) { gpio_set_level(PIN_NRF_CE, high ? 1 : 0); }

static uint8_t xfer(uint8_t cmd, const uint8_t* tx, uint8_t* rx, size_t len) {
  uint8_t out[33] = { cmd }, in[33] = {};
  if (tx && len) memcpy(out + 1, tx, len);
  spi_transaction_t t = {};
  t.length    = (len + 1) * 8;
  t.tx_buffer = out;
  t.rx_buffer = in;
  spi_device_polling_transmit(s_spi, &t);
  if (rx && len) memcpy(rx, in + 1, len);
  return in[0];   // STATUS
}

static uint8_t read_reg(uint8_t reg) {
  uint8_t v = 0;
  xfer(CMD_R_REGISTER | reg, nullptr, &v, 1);
  return v;
}
static void write_reg(uint8_t reg, uint8_t v) { xfer(CMD_W_REGISTER | reg, &v, nullptr, 1); }
static void write_reg(uint8_t reg, const uint8_t* buf, size_t n) { xfer(CMD_W_REGISTER | reg, buf, nullptr, n); }

bool nrf24_init(const uint8_t address[5], uint8_t payloadSize) {
  s_payload = payloadSize > 32 ? 32 : payloadSize;

  if (!s_spi) {
    gpio_config_t io = {};
    io.pin_bit_mask = 1ULL << PIN_NRF_CE;
    io.mode = GPIO_MODE_OUTPUT;
    gpio_config(&io);
    ce(false);

    spi_bus_config_t bus = {};
    bus.mosi_io_num = PIN_NRF_MOSI;
    bus.miso_io_num = PIN_NRF_MISO;
    bus.sclk_io_num = PIN_NRF_SCK;
    bus.quadwp_io_num = -1;
    bus.quadhd_io_num = -1;
    bus.max_transfer_sz = 64;
    ESP_ERROR_CHECK(spi_bus_initialize(SPI3_HOST, &bus, SPI_DMA_DISABLED));   // VSPI

    spi_device_interface_config_t dev = {};
    dev.mode = 0;
    dev.clock_speed_hz = 8 * 1000 * 1000;
    dev.spics_io_num = PIN_NRF_CSN;
    dev.queue_size = 1;
    ESP_ERROR_CHECK(spi_bus_add_device(SPI3_HOST, &dev, &s_spi));
  }

  ce(false);
  delay_ms(5);                                   // settling apos power-on

  write_reg(REG_SETUP_RETR, (5 << 4) | 15);      // setRetries(5, 15)
  write_reg(REG_FEATURE, 0);                     // sem payload dinamico / ack payload
  write_reg(REG_DYNPD, 0);
  write_reg(REG_EN_AA, 0x3F);                    // auto-ack em todos os pipes
  write_reg(REG_SETUP_AW, 0x03);                 // endereco de 5 bytes
  write_reg(REG_RF_CH, NRF_CHANNEL);
  write_reg(REG_RF_SETUP, 0x27);                 // 250 kbps | PA max | LNA
  for (uint8_t p = 0; p < 6; p++) write_reg(REG_RX_PW_P0 + p, s_payload);
  write_reg(REG_RX_ADDR_P1, address, 5);
  write_reg(REG_EN_RXADDR, 0x02);                // somente pipe 1 (pipe 0 reservado)
  write_reg(REG_STATUS, IRQ_ALL);
  xfer(CMD_FLUSH_RX, nullptr, nullptr, 0);
  xfer(CMD_FLUSH_TX, nullptr, nullptr, 0);

  write_reg(REG_CONFIG, CONFIG_BASE);
  bool ok = read_reg(REG_CONFIG) == CONFIG_BASE;
  write_reg(REG_CONFIG, CONFIG_BASE | PWR_UP);
  delay_ms(5);                                   // standby-I

  // startListening
  write_reg(REG_CONFIG, CONFIG_BASE | PWR_UP | PRIM_RX);
  write_reg(REG_STATUS, IRQ_ALL);
  ce(true);

  ok = ok && read_reg(REG_CONFIG) == (CONFIG_BASE | PWR_UP | PRIM_RX)
          && read_reg(REG_RF_SETUP) == 0x27
          && nrf24_chip_connected();
  if (ok) ESP_LOGI(TAG, "OK — canal %d, 250kbps, payload %d", NRF_CHANNEL, s_payload);
  else    ESP_LOGE(TAG, "FALHA na inicializacao — verifique SPI (CE=%d CSN=%d) / 3.3V",
                   PIN_NRF_CE, PIN_NRF_CSN);
  return ok;
}

bool nrf24_available() {
  return (read_reg(REG_FIFO_STATUS) & 0x01) == 0;   // RX_EMPTY = 0
}

void nrf24_read(uint8_t* buf, size_t len) {
  uint8_t tmp[32] = {};
  xfer(CMD_R_RX_PAYLOAD, nullptr, tmp, s_payload);
  memcpy(buf, tmp, len < s_payload ? len : s_payload);
  write_reg(REG_STATUS, RX_DR);
}

bool nrf24_chip_connected() {
  return read_reg(REG_SETUP_AW) == 0x03;
}
