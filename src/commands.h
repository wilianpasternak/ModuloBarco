// ================================================================
//  Fila unica de comandos -> control_task
//  Origens: BLE (texto "$XXX"), controle NRF (pacote), eventos BLE.
// ================================================================
#pragma once
#include <stdint.h>
#include <stddef.h>
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "config.h"

enum class CmdType : uint8_t {
  Unknown,            // texto nao reconhecido (so bipa, como antes)
  Anc,                // $ANC
  Nrt,                // $NRT
  Mot,                // $MOT
  AcePlus, AceMinus,  // $ACE+ / $ACE-
  GtrOn, GtrOff,      // $GTR+ / $GTR-
  GtlOn, GtlOff,      // $GTL+ / $GTL-
  UppOn, UppOff,      // $UPP+ / $UPP-
  DwnOn, DwnOff,      // $DWN+ / $DWN-
  HmnPlus, HmnMinus,  // $HMN+ / $HMN-
  Cal,                // $CAL
  CfgQuery,           // $CFG?
  HofQuery,           // $HOF?
  HofSet,             // $HOF:<n>
  Buz1, Buz0,         // $BUZ1 / $BUZ0
  Rmc,                // $RMC:<id>
  Rql,                // $RQL
  Rge, Rgd,           // $RGE / $RGD
  AcgQuery,           // $ACG?
  Cat, Cap, Gup, Inc, // $CAT: $CAP: $GUP: $INC:
  Apn, ApnOff,        // $APN / $APN-
  ApgQuery,           // $APG?  ganhos da ancora
  Apk, Api, Apd,      // $APK:<kp*10> $API:<ki*10> $APD:<kd*10>
  Apr,                // $APR   ganhos padrao
  NrfPacket,          // pacote do controle remoto (data[])
  BleConnected,
  BleDisconnected,
};

struct Command {
  CmdType type;
  int32_t arg;
  uint8_t data[NRF_PAYLOAD_SIZE];
};

void          commands_init();
QueueHandle_t commands_queue();
bool          commands_post(const Command& c, TickType_t wait = 0);

// Converte uma linha de texto do app (ja sem \r\n) em comando.
Command       commands_parse(const char* line, size_t len);
