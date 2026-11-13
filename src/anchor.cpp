#include "anchor.h"

#include <math.h>
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "buzzer.h"
#include "util.h"

static const char* TAG = "anchor";

// ================= PARAMETROS =================
static constexpr double EARTH_R       = 6371000.0;
static constexpr double DEG2RAD       = M_PI / 180.0;
static constexpr int    AVG_FIXES     = 15;       // ~3 s a 5 Hz para marcar o ponto
static constexpr float  KF_ACCEL      = 0.25f;    // ruido de processo (aceleracao, m/s^2)
static constexpr float  KF_SIGMA_V    = 0.15f;    // desvio da velocidade Doppler (m/s)
static constexpr float  HDOP_TO_M     = 1.5f;     // desvio de posicao ~ HDOP * 1.5 m
static constexpr float  HDOP_MAX      = 5.0f;     // acima disso o fix e descartado
static constexpr uint32_t GPS_LOST_MS = 2000;     // sem posicao nova -> failsafe
static constexpr float  INT_MAX_PWM   = 230.0f;   // limite da forca aprendida (barco de 700 kg / 54 lb em correnteza forte)
static constexpr float  INT_MAX_DIST  = 15.0f;    // longe do ponto nao integra (aproximacao)
#ifndef INT_MAX_SPEED
#define INT_MAX_SPEED 0.15f
#endif
#ifndef INT_LEAK_TAU
#define INT_LEAK_TAU 180.0f
#endif
static constexpr float  LAT_DAMP      = 0.5f;     // amortecimento lateral (fracao do Kd)
static constexpr float  ALIGN_MAX_DEG = 60.0f;    // alem disso a helice nao empurra
static constexpr float  CABLE_LIMIT   = 300.0f;   // giro acumulado maximo do cabo (graus)
static constexpr uint32_t DUTY_PERIOD = 2000;     // ciclo do empuxo fraco (ms)
static constexpr float  RISE_PWM_S    = 150.0f;   // subida maxima da helice (PWM/s)
static constexpr float  PREALIGN_FRAC = 0.25f;    // gira o motor a partir desta fracao do PWM minimo

// ================= FILTRO DE KALMAN (1 eixo: posicao + velocidade) =================
struct AxisKF {
  float p = 0, v = 0;              // estado
  float P00 = 25, P01 = 0, P11 = 1; // covariancia

  void reset(float pos, float vel) { p = pos; v = vel; P00 = 4; P01 = 0; P11 = 0.25f; }

  void predict(float dt) {
    p += v * dt;
    // P = F P F' + Q  (modelo de velocidade constante, aceleracao branca)
    float q   = KF_ACCEL * KF_ACCEL;
    float dt2 = dt * dt;
    float n00 = P00 + 2 * dt * P01 + dt2 * P11 + q * dt2 * dt2 / 4;
    float n01 = P01 + dt * P11 + q * dt2 * dt / 2;
    float n11 = P11 + q * dt2;
    P00 = n00; P01 = n01; P11 = n11;
  }

  // Medida de posicao e velocidade (H = I)
  void update(float zp, float zv, float rp, float rv) {
    float s00 = P00 + rp, s01 = P01, s11 = P11 + rv;
    float det = s00 * s11 - s01 * s01;
    if (fabsf(det) < 1e-9f) return;
    float i00 = s11 / det, i01 = -s01 / det, i11 = s00 / det;
    // K = P S^-1
    float k00 = P00 * i00 + P01 * i01, k01 = P00 * i01 + P01 * i11;
    float k10 = P01 * i00 + P11 * i01, k11 = P01 * i01 + P11 * i11;
    float yp = zp - p, yv = zv - v;
    p += k00 * yp + k01 * yv;
    v += k10 * yp + k11 * yv;
    // P = (I - K) P
    float n00 = (1 - k00) * P00 - k01 * P01;
    float n01 = (1 - k00) * P01 - k01 * P11;
    float n11 = -k10 * P01 + (1 - k11) * P11;
    P00 = n00; P01 = n01; P11 = n11;
  }

  // So posicao (quando nao ha curso valido)
  void update_pos(float zp, float rp) {
    float s = P00 + rp;
    float k0 = P00 / s, k1 = P01 / s;
    float y = zp - p;
    p += k0 * y; v += k1 * y;
    float n00 = (1 - k0) * P00, n01 = (1 - k0) * P01, n11 = P11 - k1 * P01;
    P00 = n00; P01 = n01; P11 = n11;
  }
};

// ================= ESTADO =================
static AnchorGains       s_gains;
static AnchorMotorParams s_motor = { 0 };
static bool     s_active = false;

static double   s_lat0 = 0, s_lon0 = 0, s_cosLat0 = 1;   // origem do plano local
static float    s_anchorN = 0, s_anchorE = 0;             // ponto da ancora (m)
static int      s_avgCount = 0;
static AxisKF   s_kfN, s_kfE;
static uint32_t s_lastFixMs = 0, s_lastSeq = 0;
static float    s_hdop = 99.0f;
static bool     s_gpsLost = false;

static float    s_intN = 0, s_intE = 0;   // forca aprendida (PWM)
static float    s_uMag = 0, s_uDir = 0;   // empuxo desejado
static float    s_align = 0;              // alinhamento do ultimo ciclo (0..1)

static bool     s_thrustOn = false;
static int      s_turnDir  = 0;     // sentido travado durante a manobra (+1 dir / -1 esq)
static float    s_pwmOut   = 0;
static uint32_t s_dutyStart = 0, s_lastStep = 0;

static float    s_cableAngle = 0, s_cableTrack = 0;

static portMUX_TYPE s_mux = portMUX_INITIALIZER_UNLOCKED;
static AnchorStatus s_status;

static const BuzStep PAT_GPS_LOST[] = { {400, 150}, {400, 150}, {400, 0} };

// ================= HELPERS =================
static void to_local(double lat, double lon, float* n, float* e) {
  *n = (float)((lat - s_lat0) * DEG2RAD * EARTH_R);
  *e = (float)((lon - s_lon0) * DEG2RAD * EARTH_R * s_cosLat0);
}

static float rad2deg360(float r) { return wrap360(r * 180.0f / (float)M_PI); }

static void publish() {
  AnchorStatus st;
  st.active   = s_active;
  st.gpsLost  = s_gpsLost;
  float eN = s_anchorN - s_kfN.p, eE = s_anchorE - s_kfE.p;
  st.distance = sqrtf(eN * eN + eE * eE);
  st.bearing  = rad2deg360(atan2f(eE, eN));
  st.speed    = sqrtf(s_kfN.v * s_kfN.v + s_kfE.v * s_kfE.v);
  st.holdPwm  = sqrtf(s_intN * s_intN + s_intE * s_intE);
  st.holdDir  = rad2deg360(atan2f(s_intE, s_intN));
  st.targetDir = s_uDir;
  st.hdop     = s_hdop;
  st.throttle = (int)s_pwmOut;
  portENTER_CRITICAL(&s_mux);
  s_status = st;
  portEXIT_CRITICAL(&s_mux);
}

// ================= API =================
void anchor_set_gains(const AnchorGains& g) { s_gains = g; }
AnchorGains anchor_get_gains() { return s_gains; }

AnchorStatus anchor_status() {
  portENTER_CRITICAL(&s_mux);
  AnchorStatus st = s_status;
  portEXIT_CRITICAL(&s_mux);
  return st;
}

void anchor_begin(const GpsData& g, float thrustHeading, const AnchorMotorParams& p) {
  s_motor   = p;
  s_lat0    = g.lat;
  s_lon0    = g.lon;
  s_cosLat0 = cos(g.lat * DEG2RAD);
  s_anchorN = s_anchorE = 0;
  s_avgCount = 1;

  float vN = 0, vE = 0;
  if (g.courseValid) {
    vN = g.speedMps * cosf(g.courseDeg * (float)DEG2RAD);
    vE = g.speedMps * sinf(g.courseDeg * (float)DEG2RAD);
  }
  s_kfN.reset(0, vN);
  s_kfE.reset(0, vE);

  s_lastFixMs = millis();
  s_lastSeq   = g.seq;
  s_hdop      = g.hdop;
  s_gpsLost   = false;
  s_intN = s_intE = 0;
  s_uMag = 0; s_uDir = thrustHeading;
  s_align = 0;
  s_thrustOn = false;
  s_turnDir  = 0;
  s_pwmOut   = 0;
  s_dutyStart = s_lastStep = millis();
  s_cableAngle = 0;
  s_cableTrack = thrustHeading;
  s_active = true;
  publish();
  ESP_LOGI(TAG, "Ativada — Kp=%.1f Ki=%.1f Kd=%.1f HDOP=%.1f",
           s_gains.kp, s_gains.ki, s_gains.kd, g.hdop);
}

void anchor_end() {
  s_active = false;
  s_pwmOut = 0;
  publish();
}

void anchor_gps_update(const GpsData& g, uint32_t now) {
  if (!s_active || g.seq == s_lastSeq) return;
  s_lastSeq = g.seq;

  float dt = clampv((now - s_lastFixMs) / 1000.0f, 0.05f, 2.0f);
  s_hdop = g.hdop;

  // Fix ruim: so propaga o filtro, sem usar a medida
  if (g.hdop > HDOP_MAX) {
    s_kfN.predict(dt); s_kfE.predict(dt);
    ESP_LOGD(TAG, "fix descartado (HDOP %.1f)", g.hdop);
    publish();
    return;
  }
  s_lastFixMs = now;
  if (s_gpsLost) {
    s_gpsLost = false;
    ESP_LOGI(TAG, "GPS de volta — retomando");
    buzzer_beep(150);
  }

  float zN, zE;
  to_local(g.lat, g.lon, &zN, &zE);

  // --- Filtro de Kalman ---
  float sp = clampv(g.hdop * HDOP_TO_M, 1.0f, 15.0f);
  float rp = sp * sp;
  float rv = KF_SIGMA_V * KF_SIGMA_V;
  s_kfN.predict(dt); s_kfE.predict(dt);
  if (g.courseValid) {
    float vN = g.speedMps * cosf(g.courseDeg * (float)DEG2RAD);
    float vE = g.speedMps * sinf(g.courseDeg * (float)DEG2RAD);
    s_kfN.update(zN, vN, rp, rv);
    s_kfE.update(zE, vE, rp, rv);
  } else {
    s_kfN.update_pos(zN, rp);
    s_kfE.update_pos(zE, rp);
  }

  // --- Ponto da ancora: media dos primeiros fixes ---
  if (s_avgCount < AVG_FIXES) {
    s_avgCount++;
    s_anchorN += (zN - s_anchorN) / s_avgCount;
    s_anchorE += (zE - s_anchorE) / s_avgCount;
  }

  // --- Controle vetorial ---
  float eN = s_anchorN - s_kfN.p, eE = s_anchorE - s_kfE.p;
  float dist = sqrtf(eN * eN + eE * eE);

  // Integra so perto do ponto e quando o empuxo esta de fato alinhado
  // (ou desligado): evita acumular erro enquanto o motor ainda gira.
  if (dist < INT_MAX_DIST && (s_align > 0.7f || !s_thrustOn)) {
    s_intN += s_gains.ki * eN * dt;
    s_intE += s_gains.ki * eE * dt;
    float im = sqrtf(s_intN * s_intN + s_intE * s_intE);
    if (im > INT_MAX_PWM) { s_intN *= INT_MAX_PWM / im; s_intE *= INT_MAX_PWM / im; }
  }

  // Lei para motor SEM RE: na direcao do ponto empurra Kp*dist - Kd*v_aprox,
  // nunca negativo (quem freia e o arrasto da agua — girar 180 graus para
  // frear custa segundos sem empuxo). Na lateral, amortece a deriva.
  float uN = s_intN, uE = s_intE;
  if (dist > 0.05f) {
    float dN = eN / dist, dE = eE / dist;                  // unitario ate o ponto
    float vr = s_kfN.v * dN + s_kfE.v * dE;                // velocidade de aproximacao
    float vtN = s_kfN.v - vr * dN, vtE = s_kfE.v - vr * dE; // velocidade lateral
    float a = s_gains.kp * dist - s_gains.kd * vr;
    if (a < 0) a = 0;
    uN += a * dN - LAT_DAMP * s_gains.kd * vtN;
    uE += a * dE - LAT_DAMP * s_gains.kd * vtE;
  }
  s_uMag = sqrtf(uN * uN + uE * uE);
  if (s_uMag > 1.0f) s_uDir = rad2deg360(atan2f(uE, uN));

  publish();
  ESP_LOGD(TAG, "D=%.2fm v=%.2fm/s u=%.0f@%.0f hold=%.0f hdop=%.1f",
           dist, sqrtf(s_kfN.v * s_kfN.v + s_kfE.v * s_kfE.v), s_uMag, s_uDir,
           sqrtf(s_intN * s_intN + s_intE * s_intE), g.hdop);
}

AnchorOutput anchor_step(float thrustHeading, bool steering, uint32_t now) {
  AnchorOutput out;
  if (!s_active) return out;
  float dt = clampv((now - s_lastStep) / 1000.0f, 0.001f, 0.2f);
  s_lastStep = now;

  // --- Failsafe de GPS ---
  if (now - s_lastFixMs > GPS_LOST_MS) {
    if (!s_gpsLost) {
      s_gpsLost = true;
      ESP_LOGW(TAG, "SEM GPS — helice e giro parados (ponto mantido)");
      buzzer_play(PAT_GPS_LOST, 3);
    }
    s_pwmOut = 0; s_thrustOn = false; s_turnDir = 0;
    publish();
    return out;
  }

  // --- Rastreio do cabo (giro acumulado do motor) ---
  s_cableAngle += wrap180(thrustHeading - s_cableTrack);
  s_cableTrack = thrustHeading;

  // --- Empuxo ligado? (histerese sobre a forca desejada) ---
  float minP = (float)(s_motor.pwmHeliceMin > 0 ? s_motor.pwmHeliceMin : 1);
  if (!s_thrustOn && s_uMag > 0.5f * minP) { s_thrustOn = true; s_dutyStart = now; }
  else if (s_thrustOn && s_uMag < 0.3f * minP) s_thrustOn = false;

  // --- Giro: aponta o motor na direcao do empuxo desejado ---
  float err = wrap180(s_uDir - thrustHeading);

  // Pre-alinha o motor mesmo com a helice parada, desde que a forca pedida
  // nao seja desprezivel (abaixo disso e ruido do GPS)
  if (s_uMag < PREALIGN_FRAC * minP) {
    s_turnDir = 0;
  } else {
    // Sentido escolhido no inicio de cada manobra e mantido ate o fim:
    // pelo caminho curto, a menos que passe do limite do cabo — ai vai
    // pelo caminho longo, desenrolando.
    if (!steering || s_turnDir == 0) {
      float turn = err;
      if (fabsf(s_cableAngle + turn) > CABLE_LIMIT) turn = turn > 0 ? turn - 360.0f : turn + 360.0f;
      s_turnDir = turn > 0 ? 1 : -1;
    }
    float rem = s_turnDir > 0 ? wrap360(err) : -wrap360(-err);   // falta girar no sentido travado
    if (fabsf(rem) > 330.0f) rem = err;   // passou um pouco do alvo: corrige pelo lado curto
    out.turn = true;
    out.turnErr = rem;
  }

  // --- Helice: proporcional ao alinhamento ---
  float aerr = fabsf(err);
  s_align = aerr < ALIGN_MAX_DEG ? cosf(aerr * (float)DEG2RAD) : 0.0f;
  float desired = s_thrustOn ? s_uMag * s_align : 0.0f;

  float target = 0;
  if (desired >= minP) {
    target = desired > 255.0f ? 255.0f : desired;
  } else if (desired > 0.25f * minP) {
    // Forca abaixo do minimo da helice: liga em minP por uma fracao do ciclo
    float frac = desired / minP;
    uint32_t phase = (now - s_dutyStart) % DUTY_PERIOD;
    target = (phase < frac * DUTY_PERIOD) ? minP : 0.0f;
  }

  // Subida limitada (sem pico de corrente); descida imediata.
  // Partindo do zero, salta direto para o minimo que gira a helice.
  if (target > s_pwmOut) {
    if (s_pwmOut < minP) s_pwmOut = target < minP ? target : minP;
    s_pwmOut = fminf(target, s_pwmOut + RISE_PWM_S * dt);
  } else {
    s_pwmOut = target;
  }
  out.throttle = (int)s_pwmOut;

  publish();
  return out;
}
