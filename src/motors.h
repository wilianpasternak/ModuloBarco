// ================================================================
//  Saidas de potencia: PWM de giro/helice (LEDC) e reles sobe/desce
//  Chamado apenas pela control_task (dona dos atuadores).
// ================================================================
#pragma once

enum class Out { Left, Right, Throttle };

// Configura reles DESLIGADOS (HIGH) e PWM em 0 antes de qualquer coisa.
void motors_init();

// duty 0..255 (255 = 100%, como o ledcWrite do Arduino)
void motorWrite(Out out, int duty);

void relayUp(bool active);
void relayDown(bool active);

// Para tudo: PWM 0 e reles desligados (failsafe)
void motors_all_off();
