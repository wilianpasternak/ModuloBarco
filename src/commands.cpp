#include "commands.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>
#include "esp_log.h"

static const char* TAG = "cmd";
static QueueHandle_t s_queue = nullptr;

void commands_init() {
  s_queue = xQueueCreate(32, sizeof(Command));
}

QueueHandle_t commands_queue() { return s_queue; }

bool commands_post(const Command& c, TickType_t wait) {
  if (!s_queue) return false;
  if (xQueueSend(s_queue, &c, wait) != pdTRUE) {
    ESP_LOGW(TAG, "Fila de comandos cheia — comando %d descartado", (int)c.type);
    return false;
  }
  return true;
}

struct TextCmd { const char* text; CmdType type; };

// Comandos de texto exato
static const TextCmd EXACT[] = {
  { "$ANC",  CmdType::Anc },      { "$NRT",  CmdType::Nrt },
  { "$MOT",  CmdType::Mot },      { "$ACE+", CmdType::AcePlus },
  { "$ACE-", CmdType::AceMinus }, { "$GTR+", CmdType::GtrOn },
  { "$GTR-", CmdType::GtrOff },   { "$GTL+", CmdType::GtlOn },
  { "$GTL-", CmdType::GtlOff },   { "$UPP+", CmdType::UppOn },
  { "$UPP-", CmdType::UppOff },   { "$DWN+", CmdType::DwnOn },
  { "$DWN-", CmdType::DwnOff },   { "$HMN+", CmdType::HmnPlus },
  { "$HMN-", CmdType::HmnMinus }, { "$CAL",  CmdType::Cal },
  { "$CFG?", CmdType::CfgQuery }, { "$HOF?", CmdType::HofQuery },
  { "$BUZ1", CmdType::Buz1 },     { "$BUZ0", CmdType::Buz0 },
  { "$RQL",  CmdType::Rql },      { "$RGE",  CmdType::Rge },
  { "$RGD",  CmdType::Rgd },      { "$ACG?", CmdType::AcgQuery },
  { "$APN",  CmdType::Apn },      { "$APN-", CmdType::ApnOff },
  { "$APG?", CmdType::ApgQuery }, { "$APR",  CmdType::Apr },
};

// Comandos com argumento numerico: "$XXX:<n>"
static const TextCmd PREFIX[] = {
  { "$HOF:", CmdType::HofSet }, { "$RMC:", CmdType::Rmc },
  { "$CAT:", CmdType::Cat },    { "$CAP:", CmdType::Cap },
  { "$GUP:", CmdType::Gup },    { "$INC:", CmdType::Inc },
  { "$APK:", CmdType::Apk },    { "$API:", CmdType::Api },
  { "$APD:", CmdType::Apd },
};

Command commands_parse(const char* line, size_t len) {
  // trim (como String::trim do Arduino)
  while (len && isspace((unsigned char)line[0])) { line++; len--; }
  while (len && isspace((unsigned char)line[len - 1])) len--;

  char buf[48];
  if (len >= sizeof(buf)) len = sizeof(buf) - 1;
  memcpy(buf, line, len);
  buf[len] = '\0';

  Command c = {};
  c.type = CmdType::Unknown;
  for (const auto& e : EXACT) {
    if (strcmp(buf, e.text) == 0) { c.type = e.type; return c; }
  }
  for (const auto& e : PREFIX) {
    size_t n = strlen(e.text);
    if (strncmp(buf, e.text, n) == 0) {
      c.type = e.type;
      c.arg  = (int32_t)atol(buf + n);   // igual a String::toInt (0 se invalido)
      return c;
    }
  }
  return c;
}
