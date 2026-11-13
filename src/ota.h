// ================================================================
//  OTA via BLE (caracteristica ffe2)
//
//  Protocolo (inalterado):
//    app -> OTA_START:<tamanho>:<versao>:<md5>   esp -> OTA_READY | OTA_ERR:<motivo>
//    app -> <chunks binarios>                    esp -> OTA_ACK:<bytes> a cada 16 KB
//    app -> OTA_END                              esp -> OTA_OK (reinicia) | OTA_ERR:<motivo>
//
//  Validacoes: cabecalho (chip ESP32 + project_name igual ao firmware
//  atual), tamanho, MD5 e ASSINATURA ECDSA (esp_ota_end). A imagem nova
//  entra em teste; se nao se confirmar, o bootloader faz rollback.
//
//  Os chunks sao copiados para uma fila e gravados pela ota_task, fora
//  da task do NimBLE.
// ================================================================
#pragma once
#include <stdint.h>
#include <stddef.h>

void ota_init();
void ota_on_write(const uint8_t* data, size_t len);   // chamado pelo callback BLE
void ota_on_disconnect();
bool ota_in_progress();

// Confirma a imagem atual (cancela rollback) se ela estiver em teste.
void ota_confirm_running_image();
