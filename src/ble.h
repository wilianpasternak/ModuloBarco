// ================================================================
//  BLE GATT (NimBLE): servico ffe0
//    ffe1 — comandos de texto (write) + respostas/telemetria (notify)
//    ffe2 — OTA (write) + status do OTA (notify)
//  Os callbacks so fazem o parse e enfileiram; nada pesado roda na
//  task do NimBLE.
// ================================================================
#pragma once
#include <stddef.h>

void ble_init();
bool ble_connected();

// Envia uma notificacao no canal de comandos (thread-safe).
void ble_send(const char* s, size_t len);
void ble_send(const char* s);
void ble_sendf(const char* fmt, ...) __attribute__((format(printf, 1, 2)));

// Notificacao no canal de OTA.
void ble_ota_send(const char* s);
