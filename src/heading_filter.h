// ================================================================
//  Filtro do rumo da bussola: estima angulo E velocidade de giro
//  (filtro alfa-beta, equivalente a um Kalman de regime de 2 estados).
//
//  A bussola gira junto com a cabeca do motor, entao a velocidade
//  estimada e a velocidade real de giro do motor — usada pelo
//  controle de giro (steer.cpp) para saber se o motor esta girando.
//
//  Sem dependencias do ESP-IDF (usado tambem no simulador).
// ================================================================
#pragma once
#include <math.h>

struct HeadingFilter {
  float alpha = 0.30f;   // correcao do angulo por amostra
  float beta  = 0.04f;   // correcao da velocidade por amostra
  float angle = 0.0f;    // graus 0..360
  float rate  = 0.0f;    // graus/s (+ = sentido horario / giro para a direita)
  bool  initialized = false;

  static float w180(float e) {
    while (e >  180.0f) e -= 360.0f;
    while (e < -180.0f) e += 360.0f;
    return e;
  }
  static float w360(float a) {
    while (a <   0.0f) a += 360.0f;
    while (a >= 360.0f) a -= 360.0f;
    return a;
  }

  void reset() { initialized = false; rate = 0.0f; }

  // Nova leitura (graus) apos dt segundos
  void update(float meas, float dt) {
    if (!initialized) { angle = meas; rate = 0.0f; initialized = true; return; }
    float pred = angle + rate * dt;
    float r = w180(meas - pred);
    angle = w360(pred + alpha * r);
    rate += (beta / dt) * r;
  }

  // Sem leitura (falha de I2C): so propaga
  void predict(float dt) {
    if (!initialized) return;
    angle = w360(angle + rate * dt);
    rate *= 0.9f;
  }
};
