// ================================================================
//  Controle do motor de giro em cascata (ancora, norte, aponta-norte)
//
//  Malha externa (angulo):    erro -> velocidade de giro desejada
//      v = Ka * |erro|, limitada a [V_MIN, V_MAX]: rapido longe do
//      alvo, desacelera perto dele e chega sem passar.
//  Malha interna (velocidade): PWM = partida + v/k + PI(v_desejada - v_real)
//      A velocidade real vem da bussola (gira com o motor). Se o motor
//      nao gira, o integral sobe o PWM ate vencer o atrito.
//  Aprendizado: o PWM com que o motor efetivamente comeca a girar e
//      memorizado e usado como partida da proxima manobra (muda com
//      cabo torcido, helice empurrando, bateria...).
//  Protecao: PWM no maximo sem girar por 2 s -> corta e sinaliza
//      travamento; nova tentativa apos 5 s.
//
//  Convencao: saida > 0 gira para a direita (rumo aumenta),
//             saida < 0 para a esquerda. |saida| = PWM 0..255.
//  Sem dependencias do ESP-IDF (usado tambem no simulador).
// ================================================================
#pragma once
#include <stdint.h>

struct SteerParams {
  float pwmStart = 90.0f;    // PWM minimo que faz o giro sair do lugar (sem empuxo)
  float pwmMax   = 255.0f;
  float startDeg = 5.0f;     // comeca a corrigir acima deste erro
  float stopDeg  = 2.0f;     // considera alinhado abaixo deste erro
  uint32_t minGapMs = 0;     // intervalo minimo entre o fim de uma manobra e a proxima
};

struct Steer {
  SteerParams p;
  // estado
  bool     active      = false;
  float    integ       = 0.0f;    // integral da malha de velocidade (PWM)
  float    learnStart  = 90.0f;   // PWM de partida aprendido
  bool     moving      = false;   // ja venceu o atrito nesta manobra
  float    stallTime   = 0.0f;    // s com PWM alto e sem girar
  uint32_t stallUntil  = 0;       // ms: travado, aguardando nova tentativa
  bool     stalled     = false;   // sinaliza travamento (para bipar/avisar)
  int      lastOut     = 0;
  uint32_t lastEnd     = 0;       // ms: fim da ultima manobra

  void reset();
  // errDeg: quanto falta girar, COM SINAL do sentido desejado (pode passar
  // de 180 quando o sentido e forcado, ex.: desenrolar o cabo).
  // rateDegS: velocidade medida (+ = direita). dt em s. now em ms.
  // loadExtra: PWM extra de partida esperado (ex.: helice empurrando).
  int update(float errDeg, float rateDegS, float dt, uint32_t now, float loadExtra = 0.0f);
  void stop() { active = false; integ = 0; moving = false; stallTime = 0; lastOut = 0; }
  // Encerra a manobra marcando o horario (respeita minGapMs na proxima)
  void finish(uint32_t now) { if (active) lastEnd = now; stop(); }
  bool aligned() const { return !active; }
};
