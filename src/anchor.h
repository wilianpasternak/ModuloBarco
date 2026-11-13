// ================================================================
//  Ancora virtual — controle vetorial 2D
//
//  1. Posicao em metros (Norte/Leste) num plano local.
//  2. Filtro de Kalman por eixo (posicao + velocidade), com a
//     velocidade Doppler do GPS como medida: suaviza o ruido do GPS
//     sem o atraso de uma media movel.
//  3. Ponto da ancora = media dos primeiros ~3 s de fixes.
//  4. Empuxo desejado (vetor, em unidades de PWM):
//        u = integral(Ki*erro)                         (vetor)
//          + max(0, Kp*dist - Kd*v_aprox) * dir_ponto
//          - 0.5*Kd * v_lateral
//     O integral vetorial aprende a direcao e a forca do vento /
//     correnteza: no ponto, o motor fica apontado contra ela com a
//     forca necessaria, em vez de esperar o barco sair do raio.
//     Na direcao do ponto o termo nunca e negativo: sem re, frear
//     girando 180 graus custa segundos sem empuxo — quem freia e o
//     arrasto da agua. Na lateral, amortece a deriva.
//  5. Direcao de u -> rumo do motor (o giro e feito por steer.cpp).
//     Modulo de u  -> helice, proporcional ao alinhamento (cos do
//     erro de rumo). Abaixo do PWM minimo da helice, liga/desliga
//     em ciclos de 2 s (duty cycle) para entregar pouca forca media.
//  6. Sentido do giro travado por manobra, respeitando o limite do
//     cabo (+-300 graus): sem "tremer" no limite.
//  7. Failsafe: sem posicao nova por 2 s ou HDOP ruim -> helice e
//     giro parados ate o GPS voltar (o ponto e mantido).
// ================================================================
#pragma once
#include <stdint.h>
#include "gps.h"

struct AnchorGains {
  float kp = 60.0f;   // PWM por metro de erro
  float ki = 5.0f;    // PWM por (metro * segundo)
  float kd = 30.0f;   // PWM por m/s (velocidade de aproximacao)
};

// Limites e parametros do motor que a ancora precisa
struct AnchorMotorParams {
  int pwmHeliceMin;   // menor PWM que gira a helice
};

struct AnchorOutput {
  int   throttle = 0;      // 0..255
  bool  turn     = false;  // deve apontar o motor?
  float turnErr  = 0.0f;   // quanto falta girar (graus, com sinal do sentido escolhido)
};

struct AnchorStatus {
  bool  active      = false;
  bool  gpsLost     = false;
  float distance    = 0.0f;   // metros ate o ponto (posicao filtrada)
  float bearing     = 0.0f;   // rumo verdadeiro ate o ponto
  float speed       = 0.0f;   // m/s (filtrada)
  float holdPwm     = 0.0f;   // forca aprendida (integral), em PWM
  float holdDir     = 0.0f;   // direcao do empuxo de manutencao (contra a correnteza)
  float targetDir   = 0.0f;   // rumo desejado do motor
  float hdop        = 99.0f;
  int   throttle    = 0;
};

void         anchor_set_gains(const AnchorGains& g);
AnchorGains  anchor_get_gains();

// Inicia no fix atual. thrustHeading = rumo verdadeiro do empuxo (bussola + offset).
void         anchor_begin(const GpsData& g, float thrustHeading, const AnchorMotorParams& p);
void         anchor_end();

// Nova posicao do GPS (chamar a cada fix novo, ~5 Hz).
void         anchor_gps_update(const GpsData& g, uint32_t now);

// Ciclo de 50 Hz: calcula helice e giro a partir do rumo atual do motor.
// steering = o controle de giro esta no meio de uma manobra.
AnchorOutput anchor_step(float thrustHeading, bool steering, uint32_t now);

AnchorStatus anchor_status();   // thread-safe (copia)
