// ================================================================
//  GPS u-blox na UART2 (38400 / 5 Hz) + TinyGPSPlus
//  gps_task (nucleo 1): le a UART, decodifica e publica um snapshot.
// ================================================================
#pragma once
#include <stdint.h>

struct GpsData {
  bool     valid    = false;   // ja teve fix alguma vez (como TinyGPS isValid)
  double   lat      = 0.0;
  double   lon      = 0.0;
  float    speedKmh = 0.0f;
  float    speedMps = 0.0f;    // velocidade Doppler (RMC) — bem menos ruidosa que derivar a posicao
  float    courseDeg = 0.0f;   // curso sobre o fundo (verdadeiro), RMC
  bool     courseValid = false;
  float    hdop     = 99.0f;   // diluicao horizontal (GGA); 99 = desconhecido
  uint32_t sats     = 0;
  uint32_t fixMs    = 0;       // millis() da ultima posicao recebida
  uint32_t seq      = 0;       // incrementa a cada posicao nova
  uint32_t ageMs() const;      // tempo desde a ultima posicao (UINT32_MAX se invalido)
};

void    gps_start();
GpsData gps_get();
