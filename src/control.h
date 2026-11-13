// ================================================================
//  control_task (nucleo 1, 50 Hz) — unica dona do estado e dos motores
//
//  Consome a fila de comandos (BLE + NRF) e executa, a cada 20 ms:
//  rampa do motor, timeouts de hold, ancora (PID distancia + giro),
//  modo norte, aponta-norte e calibracao da bussola (maquina de estados).
// ================================================================
#pragma once
#include <stdint.h>
#include "settings.h"

struct ControlSnapshot {
  bool  anchorMode      = false;
  bool  northMode       = false;
  bool  motorLigado     = false;
  float heading         = 0.0f;
  float distancia       = 0.0f;
  float bearingFiltered = 0.0f;
  int   pwmComHeading   = 0;
};

void            control_start(const Settings& s);
ControlSnapshot control_snapshot();
uint32_t        control_cycles();   // contador de ciclos (autoteste do boot)

const char*     firmware_version(); // definido em main.cpp
