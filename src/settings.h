// ================================================================
//  Configuracoes persistentes (NVS, namespace "barco")
//
//  Mesmas chaves e tipos que a Preferences do Arduino gravava:
//  putInt -> i32, putUInt -> u32, putBool -> u8, putFloat -> blob(4).
//
//  Escritas sao agrupadas pela settings_task: cada alteracao e gravada
//  1 s apos a ultima mudanca (evita desgastar a flash a cada clique).
//  Dados criticos (calibracao, controles) usam 'immediate'.
// ================================================================
#pragma once
#include <stdint.h>
#include "config.h"

struct Settings {
  int32_t  pwmHelMin    = 0;
  int32_t  pwmMotorOff  = 0;
  int32_t  hdgOff       = 0;
  int32_t  calibTimeSeg = 10;
  int32_t  calibPwmGiro = 160;
  int32_t  usoPwmGiro   = 240;
  int32_t  aceInc       = 5;
  bool     buzzerOn     = true;
  bool     compCalib    = false;
  float    compXoff     = 0.0f;
  float    compYoff     = 0.0f;
  float    compXscl     = 1.0f;   // escala soft-iron (calibracao)
  float    compYscl     = 1.0f;
  float    compRef      = 0.0f;   // campo de referencia da calibracao (monitor)
  int32_t  ancKp10      = 600;    // ganhos da ancora x10 (Kp 60.0 / Ki 5.0 / Kd 30.0)
  int32_t  ancKi10      = 50;
  int32_t  ancKd10      = 300;
  uint32_t ctrl[MAX_CONTROLES] = {0};
};

// Inicializa a NVS e carrega os valores salvos (ou defaults).
void settings_init(Settings& out);
// Cria a task de gravacao (nucleo 0).
void settings_start();

void settings_set_i32(const char* key, int32_t v,  bool immediate = false);
void settings_set_u32(const char* key, uint32_t v, bool immediate = false);
void settings_set_bool(const char* key, bool v,    bool immediate = false);
void settings_set_float(const char* key, float v,  bool immediate = false);
