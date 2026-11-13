// ================================================================
//  Driver minimo nRF24L01(+) — somente recepcao, payload fixo
//  Replica a configuracao que a biblioteca RF24 aplicava:
//  canal 76, 250 kbps, PA max + LNA, CRC 16 bits, auto-ack,
//  endereco de 5 bytes no pipe 1, retries (5,15).
// ================================================================
#pragma once
#include <stdint.h>
#include <stddef.h>

bool nrf24_init(const uint8_t address[5], uint8_t payloadSize);
bool nrf24_available();
void nrf24_read(uint8_t* buf, size_t len);
bool nrf24_chip_connected();
