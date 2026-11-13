// ================================================================
//  Bussola HMC5883L (I2C 50 kHz) + filtro de Kalman do heading
//  compass_task: 50 Hz no nucleo 1. Publica rumo e velocidade de giro.
// ================================================================
#pragma once
#include <stdint.h>

// Inicializa I2C e o sensor; retorna false se o HMC5883L nao responder.
// Calibracao: centro (hard-iron) e escala por eixo (soft-iron simplificado).
struct CompassCal {
  float xOff = 0, yOff = 0, xScale = 1, yScale = 1;
  float ref = 0;   // intensidade do campo calibrado esperada (0 = desconhecida)
};

bool  compass_init(const CompassCal& cal);
void  compass_start();

float compass_heading();                       // 0..360, filtrado (sem headingOffset)
float compass_rate();                          // velocidade de giro (graus/s, + = direita)
bool  compass_present();                       // HMC5883L respondeu no boot

// Monitor da calibracao em uso: com a bussola bem calibrada a intensidade do
// campo lido e constante em qualquer rumo. Se ela se afastar mais de 30% da
// referencia por 3 s (motor reinstalado, metal perto, interferencia), a
// calibracao e considerada invalida ate voltar ao normal por 3 s.
bool  compass_field_fault();
float compass_field_ratio();                   // campo atual / referencia (1 = normal)
void  compass_set_calibration(const CompassCal& cal);
void  compass_reset_filter();                  // reinicia o Kalman (ativacao da ancora)

// Calibracao: acumula min/max de X/Y enquanto ativa.
void  compass_calib_begin();
bool  compass_calib_end(CompassCal* out);   // false: poucas amostras ou eixos sem amplitude (nao girou)
CompassCal compass_get_calibration();

// Verificacao da calibracao: durante um giro, registra (com a calibracao
// ATUAL aplicada, sem filtro) quais setores de 30 graus foram lidos, o giro
// acumulado e o maior salto entre leituras consecutivas (gaps = saltos).
struct CompassVerify {
  uint16_t sectors   = 0;      // bit i = setor [30*i, 30*i+30) lido
  float    rotation  = 0;      // graus acumulados (+ direita / - esquerda)
  float    maxJump   = 0;      // maior salto entre leituras consecutivas (graus)
  int      samples   = 0;
  float    fieldMin  = 0, fieldMax = 0;   // intensidade do campo calibrado (uniformidade)
};
void          compass_verify_begin();
CompassVerify compass_verify_get();
void          compass_verify_end();
