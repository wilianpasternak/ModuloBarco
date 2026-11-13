#include "ota.h"

#include <atomic>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "esp_app_desc.h"
#include "esp_app_format.h"
#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_rom_md5.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "ble.h"
#include "config.h"
#include "util.h"

static const char* TAG = "ota";

static constexpr size_t CHUNK_MAX  = 512;
static constexpr int    QUEUE_LEN  = 16;     // ~8 KB de buffer entre BLE e flash
static constexpr size_t HEADER_LEN = sizeof(esp_image_header_t) +
                                     sizeof(esp_image_segment_header_t) +
                                     sizeof(esp_app_desc_t);

enum class MsgKind : uint8_t { Start, Data, End, Abort };

struct OtaMsg {
  MsgKind  kind;
  uint16_t len;
  uint8_t  data[CHUNK_MAX];
};

static QueueHandle_t     s_queue = nullptr;
// Sessao aberta: o callback BLE so enfileira dados enquanto true.
// Abre ao receber OTA_START; fecha em OTA_END, erro ou desconexao.
static std::atomic<bool> s_active{false};

// Estado da ota_task
static esp_ota_handle_t       s_handle = 0;
static const esp_partition_t* s_part = nullptr;
static size_t        s_expected = 0, s_received = 0;
static bool          s_hasMd5 = false;
static uint8_t       s_md5Expected[16];
static md5_context_t s_md5;
static uint8_t       s_header[HEADER_LEN];
static size_t        s_headerLen = 0;
static bool          s_headerOk = false;

static void reply(const char* s) {
  ESP_LOGI(TAG, "%.*s", (int)strcspn(s, "\n"), s);
  ble_ota_send(s);
}

static void abort_ota() {
  if (s_handle) { esp_ota_abort(s_handle); s_handle = 0; }
  s_active = false;
}

static void fail(const char* reason) {
  char buf[64];
  snprintf(buf, sizeof(buf), "OTA_ERR:%s\n", reason);
  abort_ota();
  reply(buf);
}

static bool parse_md5(const char* hex, uint8_t out[16]) {
  if (strlen(hex) < 32) return false;
  for (int i = 0; i < 16; i++) {
    char b[3] = { hex[i * 2], hex[i * 2 + 1], 0 };
    char* end;
    out[i] = (uint8_t)strtoul(b, &end, 16);
    if (*end) return false;
  }
  return true;
}

// Formato: OTA_START:<size>:<version>:<md5>
static void handle_start(const char* s) {
  if (s_handle) abort_ota();
  const char* p = s + strlen("OTA_START:");
  s_expected = strtoul(p, nullptr, 10);
  const char* c1 = strchr(p, ':');
  const char* c2 = c1 ? strchr(c1 + 1, ':') : nullptr;
  char ver[32] = "?";
  if (c1 && c2) snprintf(ver, sizeof(ver), "%.*s", (int)(c2 - c1 - 1), c1 + 1);
  s_hasMd5 = c2 && parse_md5(c2 + 1, s_md5Expected);
  ESP_LOGI(TAG, "Inicio: %u bytes, versao %s, md5 %s",
           (unsigned)s_expected, ver, s_hasMd5 ? "sim" : "nao");

  s_part = esp_ota_get_next_update_partition(nullptr);
  if (!s_part)                         { fail("no partition"); return; }
  if (s_expected == 0 ||
      s_expected > s_part->size)       { fail("invalid size"); return; }

  // Escrita sequencial: apaga setor a setor durante a gravacao (OTA_START responde na hora)
  esp_err_t err = esp_ota_begin(s_part, OTA_WITH_SEQUENTIAL_WRITES, &s_handle);
  if (err != ESP_OK) {
    s_handle = 0;
    ESP_LOGE(TAG, "esp_ota_begin: %s", esp_err_to_name(err));
    fail("begin failed");
    return;
  }
  esp_rom_md5_init(&s_md5);
  s_received = 0;
  s_headerLen = 0;
  s_headerOk = false;
  reply("OTA_READY\n");
}

// Confere chip e nome do projeto antes de aceitar o resto da imagem
static bool check_header() {
  const esp_image_header_t* h = (const esp_image_header_t*)s_header;
  if (h->magic != ESP_IMAGE_HEADER_MAGIC || h->chip_id != ESP_CHIP_ID_ESP32) {
    fail("not an ESP32 image");
    return false;
  }
  esp_app_desc_t desc;
  memcpy(&desc, s_header + sizeof(esp_image_header_t) + sizeof(esp_image_segment_header_t),
         sizeof(desc));
  const esp_app_desc_t* self = esp_app_get_description();
  if (desc.magic_word != ESP_APP_DESC_MAGIC_WORD ||
      strncmp(desc.project_name, self->project_name, sizeof(desc.project_name)) != 0) {
    fail("wrong firmware");
    return false;
  }
  ESP_LOGI(TAG, "Imagem '%s' versao %s", desc.project_name, desc.version);
  return true;
}

static void handle_data(const uint8_t* d, size_t n) {
  if (!s_handle) return;
  if (s_received + n > s_expected) { fail("too much data"); return; }

  if (!s_headerOk) {
    size_t take = HEADER_LEN - s_headerLen;
    if (take > n) take = n;
    memcpy(s_header + s_headerLen, d, take);
    s_headerLen += take;
    if (s_headerLen == HEADER_LEN) {
      if (!check_header()) return;
      s_headerOk = true;
    }
  }

  esp_err_t err = esp_ota_write(s_handle, d, n);
  if (err != ESP_OK) {
    ESP_LOGE(TAG, "esp_ota_write: %s", esp_err_to_name(err));
    fail("write failed");
    return;
  }
  esp_rom_md5_update(&s_md5, d, n);
  size_t before = s_received;
  s_received += n;
  if (s_received / (16 * 1024) != before / (16 * 1024)) {   // a cada 16 KB
    char ack[32];
    snprintf(ack, sizeof(ack), "OTA_ACK:%u\n", (unsigned)s_received);
    ble_ota_send(ack);
    ESP_LOGD(TAG, "%u/%u bytes", (unsigned)s_received, (unsigned)s_expected);
  }
}

static void handle_end() {
  if (!s_handle) return;
  if (s_received != s_expected) { fail("size mismatch"); return; }

  uint8_t md5[16];
  esp_rom_md5_final(md5, &s_md5);
  if (s_hasMd5 && memcmp(md5, s_md5Expected, 16) != 0) { fail("md5 mismatch"); return; }

  // Valida a imagem inteira: checksum, SHA-256 e assinatura ECDSA
  esp_err_t err = esp_ota_end(s_handle);
  s_handle = 0;
  if (err != ESP_OK) {
    ESP_LOGE(TAG, "esp_ota_end: %s", esp_err_to_name(err));
    s_active = false;
    reply(err == ESP_ERR_OTA_VALIDATE_FAILED ? "OTA_ERR:invalid signature\n"
                                             : "OTA_ERR:end failed\n");
    return;
  }
  err = esp_ota_set_boot_partition(s_part);
  s_active = false;
  if (err != ESP_OK) {
    ESP_LOGE(TAG, "esp_ota_set_boot_partition: %s", esp_err_to_name(err));
    reply("OTA_ERR:set boot failed\n");
    return;
  }
  reply("OTA_OK\n");
  delay_ms(500);           // tempo para a notificacao sair
  esp_restart();
}

static void ota_task(void*) {
  static OtaMsg m;   // static: nao ocupa stack
  for (;;) {
    xQueueReceive(s_queue, &m, portMAX_DELAY);
    switch (m.kind) {
      case MsgKind::Start: m.data[m.len < CHUNK_MAX ? m.len : CHUNK_MAX - 1] = 0;
                           handle_start((const char*)m.data); break;
      case MsgKind::Data:  handle_data(m.data, m.len); break;
      case MsgKind::End:   handle_end(); break;
      case MsgKind::Abort: if (s_handle) { ESP_LOGW(TAG, "Abortado (desconexao)"); abort_ota(); } break;
    }
  }
}

void ota_init() {
  s_queue = xQueueCreate(QUEUE_LEN, sizeof(OtaMsg));
  xTaskCreatePinnedToCore(ota_task, "ota", STACK_OTA, nullptr, PRIO_OTA, nullptr, CORE_COMM);
}

static void enqueue(MsgKind kind, const uint8_t* d, size_t n) {
  static OtaMsg m;   // usado so pela task do NimBLE
  m.kind = kind;
  m.len  = (uint16_t)(n > CHUNK_MAX ? CHUNK_MAX : n);
  if (d && m.len) memcpy(m.data, d, m.len);
  // Bloqueia o NimBLE se a flash estiver atrasada (controle de fluxo natural)
  if (xQueueSend(s_queue, &m, pdMS_TO_TICKS(2000)) != pdTRUE) {
    ESP_LOGE(TAG, "Fila OTA travada — abortando");
    s_active = false;
    m.kind = MsgKind::Abort; m.len = 0;
    xQueueSend(s_queue, &m, 0);
  }
}

void ota_on_write(const uint8_t* d, size_t n) {
  if (n == 0) return;
  // Comandos de texto sao curtos; chunks binarios usam o MTU inteiro
  if (n < 100 && n >= 10 && memcmp(d, "OTA_START:", 10) == 0) {
    char tmp[100];
    memcpy(tmp, d, n); tmp[n] = 0;
    tmp[strcspn(tmp, "\r\n")] = 0;
    s_active = true;
    enqueue(MsgKind::Start, (const uint8_t*)tmp, strlen(tmp) + 1);
    return;
  }
  if (n <= 16 && n >= 7 && memcmp(d, "OTA_END", 7) == 0) {
    if (!s_active) return;
    s_active = false;
    enqueue(MsgKind::End, nullptr, 0);
    return;
  }
  if (s_active) {
    // Divide se o chunk for maior que o buffer (MTU > 515)
    while (n > 0) {
      size_t k = n > CHUNK_MAX ? CHUNK_MAX : n;
      enqueue(MsgKind::Data, d, k);
      d += k; n -= k;
    }
  }
}

void ota_on_disconnect() {
  s_active = false;
  enqueue(MsgKind::Abort, nullptr, 0);
}

bool ota_in_progress() { return s_active || s_handle != 0; }

void ota_confirm_running_image() {
  const esp_partition_t* running = esp_ota_get_running_partition();
  esp_ota_img_states_t state;
  if (esp_ota_get_state_partition(running, &state) == ESP_OK &&
      state == ESP_OTA_IMG_PENDING_VERIFY) {
    esp_ota_mark_app_valid_cancel_rollback();
    ESP_LOGI(TAG, "Firmware novo confirmado — rollback cancelado");
  }
}
