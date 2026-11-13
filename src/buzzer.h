// ================================================================
//  Buzzer nao bloqueante: padroes tocados por uma task propria.
//  Um novo pedido substitui o padrao em andamento.
// ================================================================
#pragma once
#include <stdint.h>

struct BuzStep {
  uint16_t on_ms;    // tempo ligado (0 = nao liga; BUZ_HOLD = fica ligado ate o proximo pedido)
  uint16_t off_ms;   // tempo desligado depois
};
static constexpr uint16_t BUZ_HOLD = 0xFFFF;
static constexpr int      BUZ_MAX_STEPS = 8;

void buzzer_init(bool enabled);
void buzzer_set_enabled(bool enabled);
bool buzzer_enabled();

void buzzer_play(const BuzStep* steps, int n);
void buzzer_beep(uint16_t ms);
void buzzer_hold(bool on);    // liga continuo / desliga
