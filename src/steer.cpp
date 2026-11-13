#include "steer.h"

#include <math.h>

// Malha externa: velocidade de giro desejada a partir do erro
static constexpr float KA = 2.5f;   // (graus/s) por grau de erro
static constexpr float V_MIN   = 10.0f;   // graus/s (perto do alvo)
static constexpr float V_MAX = 110.0f;   // graus/s: acima do que o motor alcanca -> PWM maximo em giros grandes

// Malha interna: PWM a partir da velocidade
static constexpr float K_RATE  = 0.55f;   // graus/s por PWM acima da partida (estimativa)
static constexpr float KP_V = 1.0f;   // PWM por (grau/s) de erro de velocidade
static constexpr float KI_V = 2.0f;   // PWM/s por (grau/s) de erro de velocidade
static constexpr float BRAKE_MAX = 120.0f; // PWM maximo no sentido contrario (frenagem)

// Deteccao de movimento / travamento
static constexpr float MOVE_RATE  = 8.0f;   // graus/s: venceu o atrito
static constexpr float STALL_RATE = 3.0f;   // graus/s: considerado parado
static constexpr float STALL_S    = 2.0f;   // s no PWM maximo sem girar
static constexpr uint32_t RETRY_MS = 5000;  // espera antes de tentar de novo

static float clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }

void Steer::reset() {
  stop();
  learnStart = p.pwmStart;
  stalled = false;
  stallUntil = 0;
}

int Steer::update(float err, float rate, float dt, uint32_t now, float loadExtra) {
  if ((int32_t)(stallUntil - now) > 0) { lastOut = 0; return 0; }   // travado: aguarda

  float a = fabsf(err);
  if (!active) {
    if (a <= p.startDeg || (now - lastEnd) < p.minGapMs) { lastOut = 0; return 0; }
    active = true; integ = 0; moving = false; stallTime = 0;
  }
  if (a < p.stopDeg) { finish(now); return 0; }

  float dir = err > 0 ? 1.0f : -1.0f;
  float vd  = clampf(KA * a, V_MIN, V_MAX);       // velocidade desejada (no sentido do erro)
  float v   = rate * dir;                          // velocidade real no mesmo sentido
  float ev  = vd - v;

  // Partida aprendida + feed-forward da velocidade pedida
  float base = learnStart + loadExtra;
  float ff   = base + vd / K_RATE;

  integ += KI_V * ev * dt;
  integ  = clampf(integ, -(base + BRAKE_MAX), p.pwmMax);   // anti-windup

  float out = clampf(ff + KP_V * ev + integ, -BRAKE_MAX, p.pwmMax);

  // Aprendizado: PWM com que o motor efetivamente saiu do lugar
  if (!moving && v > MOVE_RATE) {
    moving = true;
    stalled = false;
    float startNow = fmaxf(out - vd / K_RATE, p.pwmStart);   // parte "de atrito" do PWM atual
    learnStart = clampf(0.7f * learnStart + 0.3f * startNow, p.pwmStart, p.pwmMax * 0.9f);
  }

  // Protecao: PWM no maximo e o motor nao gira
  if (out >= p.pwmMax - 1.0f && v < STALL_RATE) {
    stallTime += dt;
    if (stallTime > STALL_S) {
      stop();
      stalled = true;
      stallUntil = now + RETRY_MS;
      return 0;
    }
  } else {
    stallTime = 0;
  }

  lastOut = (int)lroundf(out * dir);
  return lastOut;
}
