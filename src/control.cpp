#include "control.h"

#include <atomic>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "esp_log.h"
#include "esp_task_wdt.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "anchor.h"
#include "ble.h"
#include "buzzer.h"
#include "commands.h"
#include "compass.h"
#include "config.h"
#include "gps.h"
#include "motors.h"
#include "settings.h"
#include "steer.h"
#include "telemetry.h"
#include "util.h"

static const char* TAG = "control";

// ================= ESTADOS =================
static bool anchorMode      = false;
static bool northMode       = false;
static bool motorLigado     = false;
static bool calibrando      = false;
static bool apontaNorteMode = false;

// ================= ANCORA (logica em anchor.cpp) =================
static int      pwmHeliceMin    = 0;
static int      pwmMotorOff     = 0;    // pwmHeliceMin - 5: pre-carga no ESC sem girar
static int      pwmComHeading   = 0;    // helice comandada pela ancora (telemetria)
static uint32_t anchorStartTime = 0;
static uint32_t lastAnchorSeq   = 0;

// ================= HEADING =================
static float    heading            = 0;
static int      headingOffset      = 0;
static float    northHeadingTarget = 0;

// ================= GIRO =================
// Controle automatico (ancora, norte, aponta-norte): cascata em steer.cpp
static Steer           steer;
static bool            steerStalledPrev = false;
static int             usoPwmGiro  = 240;          // PWM do giro manual
static int             aceleracaoIncremento = 5;   // passo do acelerador por clique
static int             calibTimeSeg = 10;          // segundos por lado na calibracao
static int             calibPwmGiro = 160;         // PWM giro na calibracao

// ================= CONTROLE =================
static int aceleracao = 0;

// ================= RAMPA MOTOR (religamento manual) =================
// Ao religar o motor em modo manual, sobe de 0 ate "aceleracao" em
// motorRampDuracao ms, evitando pico de corrente.
static bool     motorRampAtiva = false;
static uint32_t motorRampStart = 0;
static int      motorRampAlvo  = 0;
static constexpr uint32_t motorRampDuracao = 1500;

// ================= HOLD BLE =================
static bool     giroDir = false, giroEsq = false, upAtivo = false, downAtivo = false;
static uint32_t lastGiroCmdTime = 0, lastUpDownCmdTime = 0;
static constexpr uint32_t holdTimeout = 150;   // ms sem novo comando para parar

// ================= NRF =================
static uint32_t controlesMem[MAX_CONTROLES] = {0};
static int8_t   remoteBatt[MAX_CONTROLES]   = {-1, -1, -1, -1, -1};
static uint32_t bootTime        = 0;
static bool     modoCadastro    = true;
static bool     modoCadastroBLE = false;   // ativado via BLE $RGE, sem timeout de boot
static constexpr uint32_t cadastroTimeout = 1000;
static uint32_t tempoLigadoGiro = 0, tempoLigadoUpDown = 0;
// Janela em que pacotes NRF sao ignorados (substitui os delay(300/2000)
// bloqueantes: evita repetir a acao enquanto o botao continua apertado)
static uint32_t nrfLockUntil = 0;

// ================= BLE =================
static bool     pendingHmnNotify = false;
static uint32_t hmnNotifyTime    = 0;

// ================= CALIBRACAO (maquina de estados) =================
enum class CalStep { Idle, Pause1, SpinLeft, Pause2, SpinRight, Pause3, VerifyLeft, Pause4, VerifyRight };
static CalStep  calStep      = CalStep::Idle;
static uint32_t calStepStart = 0;
static bool    bussolaCalibrada = false;   // calibracao aprovada gravada
static int     bussolaEstadoPrev = -1;
static CompassCal calPrev;            // calibracao anterior (restaurada se a nova for reprovada)
static CompassCal calNew;
static CompassVerify calVerLeft;
static constexpr float    VERIFY_TURN_DEG   = 540.0f;   // 1,5 volta para cada lado
static constexpr uint32_t VERIFY_TIMEOUT_MS = 25000;
static constexpr float    VERIFY_MAX_JUMP   = 20.0f;    // salto maximo entre leituras (gap)
static constexpr float    VERIFY_FIELD_RATIO = 2.0f;    // campo max/min ao longo da volta
static constexpr uint16_t ALL_SECTORS = 0x0FFF;          // 12 setores de 30 graus

// ================= SNAPSHOT / AUTOTESTE =================
static portMUX_TYPE          s_snapMux = portMUX_INITIALIZER_UNLOCKED;
static ControlSnapshot       s_snap;
static std::atomic<uint32_t> s_cycles{0};

// ================= BUZZER (padroes) =================
static constexpr uint16_t BEEP_CMD = 20;   // confirmacao de comando BLE / pacote NRF
static const BuzStep PAT_ANCORA_ON[]   = { {150, 50}, {150, 0} };
static const BuzStep PAT_ANCORA_ERRO[] = { {80, 80}, {80, 80}, {80, 80} };
static const BuzStep PAT_NAO_AUTORIZ[] = { {50, 50}, {50, 50}, {50, 50} };
static const BuzStep PAT_CALIB_FIM[]   = { {0, 1000}, {200, 200}, {200, 200}, {200, 200} };
static const BuzStep PAT_CALIB_ERRO[]  = { {1000, 200}, {100, 100}, {100, 100}, {100, 0} };
static const BuzStep PAT_BUSSOLA_ERRO[] = { {400, 100}, {100, 100}, {400, 0} };
static const BuzStep PAT_BOOT[]        = { {0, 1000}, {80, 200}, {80, 200}, {80, 200} };

static const BuzStep PAT_GIRO_TRAVADO[] = { {600, 200}, {600, 0} };

static bool bussolaPronta();   // definida em ESTADO DA BUSSOLA

// Aplica a saida do controle de giro: > 0 direita, < 0 esquerda
static void giroWrite(int out) {
  if (out > 0)      { motorWrite(Out::Right, out);  motorWrite(Out::Left, 0); }
  else if (out < 0) { motorWrite(Out::Left, -out);  motorWrite(Out::Right, 0); }
  else              { motorWrite(Out::Left, 0);     motorWrite(Out::Right, 0); }
}

// Um passo do controle automatico de giro para o erro dado (graus, com sinal)
static void steerTo(float err, uint32_t now) {
  giroWrite(steer.update(err, compass_rate(), CONTROL_PERIOD_MS / 1000.0f, now));
}

static void steerStop() {
  steer.stop();
  giroWrite(0);
}

// Zona de atuacao por modo:
//  - Ancora: a precisao e limitada pelo GPS; 10 graus de erro custam so 1,5%
//    de empuxo (cos 10). Zona larga + intervalo entre manobras = mesma
//    precisao com ~40% menos tempo de giro ligado.
//  - Norte / aponta-norte: o alvo e fixo e o rumo e o objetivo -> zona apertada.
enum class SteerMode { Anchor, North, PointNorth };
static void steerConfigure(SteerMode m) {
  switch (m) {
    case SteerMode::Anchor:     steer.p.startDeg = 10.0f; steer.p.stopDeg = 3.0f; steer.p.minGapMs = 1500; break;
    case SteerMode::North:      steer.p.startDeg = 5.0f;  steer.p.stopDeg = 2.0f; steer.p.minGapMs = 0;    break;
    case SteerMode::PointNorth: steer.p.startDeg = 4.0f;  steer.p.stopDeg = 1.5f; steer.p.minGapMs = 0;    break;
  }
  steer.stop();
}

// ================= HELPERS =================
static void pararGiro() {
  giroDir = false; giroEsq = false;
  motorWrite(Out::Left, 0); motorWrite(Out::Right, 0);
}

static void pararUpDown() {
  upAtivo = false; downAtivo = false;
  relayUp(false); relayDown(false);
}

static void ligarMotor() {
  motorLigado = true;
  if (aceleracao < pwmHeliceMin) aceleracao = pwmHeliceMin;
  motorRampAlvo  = aceleracao;
  motorRampStart = millis();
  motorRampAtiva = true;
}

static void desligarMotor() {
  motorLigado    = false;
  motorRampAtiva = false;
  motorWrite(Out::Throttle, pwmMotorOff);
}

static void nrfLock(uint32_t ms) { nrfLockUntil = millis() + ms; }

static void sendRemMsg() {
  char msg[96];
  int n = snprintf(msg, sizeof(msg), "$REM:");
  for (int i = 0; i < MAX_CONTROLES; i++) {
    if (i > 0) n += snprintf(msg + n, sizeof(msg) - n, ",");
    if (controlesMem[i] != 0)
      n += snprintf(msg + n, sizeof(msg) - n, "%05u:%d", (unsigned)controlesMem[i],
                    remoteBatt[i] >= 0 ? (int)remoteBatt[i] : -1);
    else
      n += snprintf(msg + n, sizeof(msg) - n, "00000:-1");
  }
  snprintf(msg + n, sizeof(msg) - n, "\n");
  ble_send(msg);
}

static void sendAdvCfg() {
  ble_sendf("$ACG:%d:%d:%d:%d\n", calibTimeSeg, calibPwmGiro, usoPwmGiro, aceleracaoIncremento);
}

static void sendAnchorGains() {
  AnchorGains g = anchor_get_gains();
  ble_sendf("$APG:%d:%d:%d\n", (int)lroundf(g.kp * 10), (int)lroundf(g.ki * 10),
            (int)lroundf(g.kd * 10));
}

static void setAnchorGain(CmdType t, int32_t v10) {
  AnchorGains g = anchor_get_gains();
  switch (t) {
    case CmdType::Apk: v10 = clampv(v10, (int32_t)0, (int32_t)1000); g.kp = v10 / 10.0f;
                       settings_set_i32("ancKp", v10); break;
    case CmdType::Api: v10 = clampv(v10, (int32_t)0, (int32_t)200);  g.ki = v10 / 10.0f;
                       settings_set_i32("ancKi", v10); break;
    case CmdType::Apd: v10 = clampv(v10, (int32_t)0, (int32_t)3000); g.kd = v10 / 10.0f;
                       settings_set_i32("ancKd", v10); break;
    default: {         // Apr: padrao
      AnchorGains d;
      g = d;
      settings_set_i32("ancKp", (int32_t)lroundf(d.kp * 10));
      settings_set_i32("ancKi", (int32_t)lroundf(d.ki * 10));
      settings_set_i32("ancKd", (int32_t)lroundf(d.kd * 10));
      break;
    }
  }
  anchor_set_gains(g);
  sendAnchorGains();
}

static void sendHmn() { ble_sendf("$HMN:%d\n", pwmHeliceMin); }
static void sendVer() { ble_sendf("$VER:%s\n", firmware_version()); }
static void sendHof() { ble_sendf("$HOF:%d\n", headingOffset); }

static void salvarControle(uint8_t slot, uint32_t id) {
  controlesMem[slot] = id;
  char key[8]; snprintf(key, sizeof(key), "ctrl%u", slot);
  settings_set_u32(key, id, true);
  // (slot+1) bipes de 300 ms
  BuzStep pat[MAX_CONTROLES];
  for (int i = 0; i <= slot; i++) pat[i] = { 300, 200 };
  buzzer_play(pat, slot + 1);
  ESP_LOGI(TAG, "Controle %05u cadastrado no slot %u", (unsigned)id, slot);
}

static bool controleAutorizado(uint32_t id) {
  for (int i = 0; i < MAX_CONTROLES; i++)
    if (controlesMem[i] == id && id != 0) return true;
  return false;
}

// ================= ANCORA =================
static void resetAnchorState() {
  anchorMode     = false;
  anchor_end();
  pwmComHeading  = 0;
  motorRampAtiva = false;
  steer.stop();
  motorWrite(Out::Throttle, 0);
  motorWrite(Out::Left, 0);
  motorWrite(Out::Right, 0);
}

static float thrustHeading() { return wrap360(heading + (float)headingOffset); }

static void ativarAncora() {
  if (!bussolaPronta()) return;
  GpsData g = gps_get();
  bool gpsOk = g.valid && g.ageMs() < 2000 && (g.lat != 0.0 || g.lon != 0.0);
  if (gpsOk) {
    northMode       = false;
    anchorMode      = true;
    motorRampAtiva  = false;
    pwmComHeading   = 0;
    giroDir = giroEsq = false;
    compass_reset_filter();
    anchorStartTime = millis();
    lastAnchorSeq   = g.seq;
    steerConfigure(SteerMode::Anchor);
    AnchorMotorParams mp;
    mp.pwmHeliceMin = pwmHeliceMin;
    anchor_begin(g, thrustHeading(), mp);
    ESP_LOGI(TAG, "ANCORA ATIVADA — GPS age %lu ms, sats %lu, HDOP %.1f",
             (unsigned long)g.ageMs(), (unsigned long)g.sats, g.hdop);
    buzzer_play(PAT_ANCORA_ON, 2);
  } else {
    ESP_LOGW(TAG, "GPS invalido — ancora NAO ativada (valid=%d age=%lu)",
             g.valid, (unsigned long)g.ageMs());
    buzzer_play(PAT_ANCORA_ERRO, 3);
  }
}

static void desativarAncora() {
  ESP_LOGI(TAG, "ANCORA DESATIVADA — %.1f s ativa", (millis() - anchorStartTime) / 1000.0f);
  resetAnchorState();
  buzzer_beep(1500);
}

static void ativarNorte() {
  if (!bussolaPronta()) return;
  northMode = true;
  northHeadingTarget = heading;
  steerConfigure(SteerMode::North);
  buzzer_beep(150);
}

static void desativarNorte() {
  northMode    = false;
  steer.stop();
  motorRampAtiva = false;
  if (motorLigado) motorWrite(Out::Throttle, 0);
  motorWrite(Out::Left, 0); motorWrite(Out::Right, 0);
  buzzer_beep(300);
}

// ================= ESTADO DA BUSSOLA =================
// 1 = ok | 0 = nao calibrada | 2 = calibracao invalida (campo fora do esperado) | 3 = ausente
static int bussolaEstado() {
  if (!compass_present())    return 3;
  if (!bussolaCalibrada)     return 0;
  if (compass_field_fault()) return 2;
  return 1;
}

static void sendBussolaEstado() { ble_sendf("$BSC:%d\n", bussolaEstado()); }

// Modos automaticos (ancora, norte, aponta-norte) exigem bussola calibrada e
// valida. Retorna false (com bipes e aviso no app) se nao puder usar.
static bool bussolaPronta() {
  if (bussolaEstado() == 1) return true;
  ESP_LOGW(TAG, "Modo automatico bloqueado — bussola: %d", bussolaEstado());
  buzzer_play(PAT_BUSSOLA_ERRO, 3);
  sendBussolaEstado();
  return false;
}

// ================= CALIBRACAO BUSSOLA =================
// 1) Gira calibTimeSeg s para cada lado coletando min/max de X/Y.
// 2) Confere a coerencia (amplitude dos eixos) e APLICA a nova calibracao.
// 3) Verificacao: 1,5 volta para cada lado lendo o rumo JA calibrado (sem
//    filtro). Cada sentido precisa passar pelos 12 setores de 30 graus, sem
//    saltos entre leituras (o "buraco" de uma bussola mal calibrada aparece
//    como salto) e com intensidade de campo uniforme.
// 4) Aprovada: grava na NVS. Reprovada: restaura a calibracao anterior.
// Nao bloqueia: BLE, telemetria e watchdog seguem funcionando.
static void iniciarCalibracao() {
  if (calibrando) return;
  ESP_LOGI(TAG, "CALIBRACAO iniciada — %d s por lado, PWM %d", calibTimeSeg, calibPwmGiro);
  calibrando   = true;
  giroDir = giroEsq = false;
  steerStop();
  buzzer_hold(false);
  calPrev      = compass_get_calibration();
  calStep      = CalStep::Pause1;
  calStepStart = millis();
  ble_send("$CAL:1\n");
}

static void finalizarCalibracao(bool ok, const char* motivo) {
  motorWrite(Out::Left, 0); motorWrite(Out::Right, 0);
  compass_verify_end();
  calStep = CalStep::Idle;
  calibrando = false;
  if (ok) {
    settings_set_float("compXoff", calNew.xOff, true);
    settings_set_float("compYoff", calNew.yOff, true);
    settings_set_float("compXscl", calNew.xScale, true);
    settings_set_float("compYscl", calNew.yScale, true);
    settings_set_float("compRef", calNew.ref, true);
    settings_set_bool("compCalib", true, true);
    bussolaCalibrada = true;
    ESP_LOGI(TAG, "CALIBRACAO APROVADA — Xoff=%.2f Yoff=%.2f escala X=%.3f Y=%.3f (salvo NVS)",
             calNew.xOff, calNew.yOff, calNew.xScale, calNew.yScale);
    buzzer_play(PAT_CALIB_FIM, 4);
    ble_send("$CAL:OK\n");
    sendBussolaEstado();
  } else {
    compass_set_calibration(calPrev);       // volta para a calibracao anterior
    compass_reset_filter();
    ESP_LOGE(TAG, "CALIBRACAO REPROVADA (%s) — calibracao anterior mantida", motivo);
    buzzer_play(PAT_CALIB_ERRO, 4);
    ble_sendf("$CAL:ERR:%s\n", motivo);
  }
}

// Avalia um sentido da verificacao; retorna nullptr se ok, ou o motivo
static const char* avaliarVerificacao(const CompassVerify& v, const char* lado) {
  static char motivo[48];
  if (fabsf(v.rotation) < VERIFY_TURN_DEG * 0.95f) {
    snprintf(motivo, sizeof(motivo), "giro_incompleto_%s", lado);
    return motivo;
  }
  if ((v.sectors & ALL_SECTORS) != ALL_SECTORS) {
    snprintf(motivo, sizeof(motivo), "setores_%s_%03X", lado, (unsigned)(v.sectors & ALL_SECTORS));
    return motivo;
  }
  if (v.maxJump > VERIFY_MAX_JUMP) {
    snprintf(motivo, sizeof(motivo), "saltos_%s_%.0f", lado, v.maxJump);
    return motivo;
  }
  if (v.fieldMin <= 0 || v.fieldMax / v.fieldMin > VERIFY_FIELD_RATIO) {
    snprintf(motivo, sizeof(motivo), "campo_irregular_%s", lado);
    return motivo;
  }
  return nullptr;
}

static void stepCalibracao() {
  uint32_t el = millis() - calStepStart;
  uint32_t spinMs = (uint32_t)calibTimeSeg * 1000;
  switch (calStep) {
    case CalStep::Pause1:
      if (el >= 1000) {
        compass_calib_begin();
        motorWrite(Out::Left, calibPwmGiro); motorWrite(Out::Right, 0);
        buzzer_hold(true);
        calStep = CalStep::SpinLeft; calStepStart = millis();
      }
      break;
    case CalStep::SpinLeft:
      if (el >= spinMs) {
        motorWrite(Out::Left, 0); motorWrite(Out::Right, 0);
        buzzer_hold(false);
        calStep = CalStep::Pause2; calStepStart = millis();
      }
      break;
    case CalStep::Pause2:
      if (el >= 1000) {
        motorWrite(Out::Left, 0); motorWrite(Out::Right, calibPwmGiro);
        buzzer_hold(true);
        calStep = CalStep::SpinRight; calStepStart = millis();
      }
      break;
    case CalStep::SpinRight:
      if (el >= spinMs) {
        motorWrite(Out::Left, 0); motorWrite(Out::Right, 0);
        buzzer_hold(false);
        if (!compass_calib_end(&calNew)) { finalizarCalibracao(false, "sem_leituras"); break; }
        // Coerencia: os dois eixos precisam ter amplitude parecida (giro completo)
        float ratio = calNew.xScale / calNew.yScale;
        if (ratio < 0.5f || ratio > 2.0f) { finalizarCalibracao(false, "eixos_desproporcionais"); break; }
        // Aplica a calibracao nova as leituras antes de verificar
        compass_set_calibration(calNew);
        compass_reset_filter();
        ESP_LOGI(TAG, "Calibracao aplicada — verificando (1,5 volta para cada lado)");
        ble_send("$CAL:2\n");
        calStep = CalStep::Pause3; calStepStart = millis();
      }
      break;
    case CalStep::Pause3:
      if (el >= 1000) {
        compass_verify_begin();
        motorWrite(Out::Left, calibPwmGiro); motorWrite(Out::Right, 0);
        buzzer_hold(true);
        calStep = CalStep::VerifyLeft; calStepStart = millis();
      }
      break;
    case CalStep::VerifyLeft: {
      CompassVerify v = compass_verify_get();
      if (v.rotation <= -VERIFY_TURN_DEG || el >= VERIFY_TIMEOUT_MS) {
        motorWrite(Out::Left, 0); motorWrite(Out::Right, 0);
        buzzer_hold(false);
        compass_verify_end();
        calVerLeft = v;
        ESP_LOGI(TAG, "Verificacao ESQ: giro %.0f, setores %03X, maior salto %.1f, campo %.0f-%.0f",
                 v.rotation, (unsigned)v.sectors, v.maxJump, v.fieldMin, v.fieldMax);
        const char* erro = avaliarVerificacao(v, "esq");
        if (erro) { finalizarCalibracao(false, erro); break; }
        calStep = CalStep::Pause4; calStepStart = millis();
      }
      break;
    }
    case CalStep::Pause4:
      if (el >= 1000) {
        compass_verify_begin();
        motorWrite(Out::Left, 0); motorWrite(Out::Right, calibPwmGiro);
        buzzer_hold(true);
        calStep = CalStep::VerifyRight; calStepStart = millis();
      }
      break;
    case CalStep::VerifyRight: {
      CompassVerify v = compass_verify_get();
      if (v.rotation >= VERIFY_TURN_DEG || el >= VERIFY_TIMEOUT_MS) {
        motorWrite(Out::Left, 0); motorWrite(Out::Right, 0);
        buzzer_hold(false);
        compass_verify_end();
        ESP_LOGI(TAG, "Verificacao DIR: giro %.0f, setores %03X, maior salto %.1f, campo %.0f-%.0f",
                 v.rotation, (unsigned)v.sectors, v.maxJump, v.fieldMin, v.fieldMax);
        const char* erro = avaliarVerificacao(v, "dir");
        finalizarCalibracao(erro == nullptr, erro ? erro : "");
      }
      break;
    }
    case CalStep::Idle:
      calibrando = false;
      break;
  }
}

// ================= COMANDOS BLE =================
static bool isQuery(CmdType t) {
  return t == CmdType::CfgQuery || t == CmdType::HofQuery ||
         t == CmdType::AcgQuery || t == CmdType::Rql || t == CmdType::ApgQuery;
}

static void handleBleCmd(const Command& c) {
  // Durante a calibracao so respondem consultas (nada mexe nos motores)
  if (calibrando && !isQuery(c.type)) return;
  if (c.type != CmdType::CfgQuery && !calibrando) buzzer_beep(BEEP_CMD);

  switch (c.type) {
    // --- Ancora ---
    case CmdType::Anc:
      if (!anchorMode) ativarAncora(); else desativarAncora();
      break;

    // --- Norte ---
    case CmdType::Nrt:
      if (anchorMode) resetAnchorState();
      if (!northMode) {
        ativarNorte();
      } else {
        northMode = false;
        steerStop();
        motorRampAtiva = false;
        if (motorLigado) motorWrite(Out::Throttle, 0);
        buzzer_beep(1500);
      }
      break;

    // --- Motor ON/OFF ---
    case CmdType::Mot:
      if (anchorMode) { desativarAncora(); break; }
      if (motorLigado) desligarMotor(); else ligarMotor();
      break;

    // --- Aceleracao ---
    case CmdType::AcePlus:
      if (anchorMode) { desativarAncora(); break; }
      aceleracao = clampv(aceleracao + aceleracaoIncremento, 0, 255);
      if (motorLigado) {
        if (aceleracao < pwmHeliceMin) aceleracao = pwmHeliceMin;
        motorRampAtiva = false;
        motorWrite(Out::Throttle, aceleracao);
      }
      break;
    case CmdType::AceMinus: {
      if (anchorMode) { desativarAncora(); break; }
      int minAcel = motorLigado ? pwmHeliceMin : 0;
      aceleracao = clampv(aceleracao - aceleracaoIncremento, minAcel, 255);
      if (motorLigado) { motorRampAtiva = false; motorWrite(Out::Throttle, aceleracao); }
      break;
    }

    // --- Giro direita ---
    case CmdType::GtrOn:
      if (anchorMode) { desativarAncora(); break; }
      if (northMode)  { desativarNorte();  break; }
      giroDir = true; giroEsq = false;
      motorWrite(Out::Right, usoPwmGiro); motorWrite(Out::Left, 0);
      lastGiroCmdTime = millis();
      break;
    case CmdType::GtrOff:
      giroDir = false;
      if (!giroEsq) { motorWrite(Out::Right, 0); motorWrite(Out::Left, 0); }
      break;

    // --- Giro esquerda ---
    case CmdType::GtlOn:
      if (anchorMode) { desativarAncora(); break; }
      if (northMode)  { desativarNorte();  break; }
      giroEsq = true; giroDir = false;
      motorWrite(Out::Left, usoPwmGiro); motorWrite(Out::Right, 0);
      lastGiroCmdTime = millis();
      break;
    case CmdType::GtlOff:
      giroEsq = false;
      if (!giroDir) { motorWrite(Out::Left, 0); motorWrite(Out::Right, 0); }
      break;

    // --- Subir ---
    case CmdType::UppOn:
      if (anchorMode) { desativarAncora(); break; }
      if (northMode)  { desativarNorte();  break; }
      upAtivo = true; downAtivo = false;
      relayUp(true); relayDown(false);
      lastUpDownCmdTime = millis();
      break;
    case CmdType::UppOff:
      upAtivo = false;
      if (!downAtivo) relayUp(false);
      break;

    // --- Descer ---
    case CmdType::DwnOn:
      if (anchorMode) { desativarAncora(); break; }
      if (northMode)  { desativarNorte();  break; }
      downAtivo = true; upAtivo = false;
      relayDown(true); relayUp(false);
      lastUpDownCmdTime = millis();
      break;
    case CmdType::DwnOff:
      downAtivo = false;
      if (!upAtivo) relayDown(false);
      break;

    // --- PWM helice minimo ---
    case CmdType::HmnPlus:
    case CmdType::HmnMinus:
      pwmHeliceMin = clampv(pwmHeliceMin + (c.type == CmdType::HmnPlus ? 1 : -1), 0, 255);
      pwmMotorOff  = pwmHeliceMin - 5 > 0 ? pwmHeliceMin - 5 : 0;
      motorWrite(Out::Throttle, pwmHeliceMin);
      settings_set_i32("pwmHelMin",   pwmHeliceMin);
      settings_set_i32("pwmMotorOff", pwmMotorOff);
      sendHmn();
      break;

    // --- Calibrar bussola ---
    case CmdType::Cal:
      iniciarCalibracao();
      break;

    // --- Configuracao atual (app envia apos subscribe) ---
    case CmdType::CfgQuery:
      sendHmn();
      sendVer();
      sendHof();
      ble_sendf("$BUZ:%d\n", buzzer_enabled() ? 1 : 0);
      sendBussolaEstado();
      sendRemMsg();
      battery_send();
      break;

    case CmdType::HofQuery:
      sendHof();
      break;
    case CmdType::HofSet:
      headingOffset = clampv((int)c.arg, -180, 180);
      settings_set_i32("hdgOff", headingOffset);
      sendHof();
      break;

    // --- Buzzer ---
    case CmdType::Buz1:
      buzzer_set_enabled(true);
      settings_set_bool("buzzerOn", true);
      ble_send("$BUZ:1\n");
      buzzer_beep(50);
      break;
    case CmdType::Buz0:
      buzzer_set_enabled(false);
      settings_set_bool("buzzerOn", false);
      ble_send("$BUZ:0\n");
      break;

    // --- Controles NRF ---
    case CmdType::Rmc: {
      uint32_t id = (uint32_t)c.arg;
      if (id != 0) {
        for (int i = 0; i < MAX_CONTROLES; i++) {
          if (controlesMem[i] == id) {
            controlesMem[i] = 0;
            remoteBatt[i]   = -1;
            char key[8]; snprintf(key, sizeof(key), "ctrl%d", i);
            settings_set_u32(key, 0, true);
            break;
          }
        }
      }
      sendRemMsg();
      break;
    }
    case CmdType::Rql:
      sendRemMsg();
      break;
    case CmdType::Rge:
      modoCadastroBLE = true;
      ble_send("$RGM:1\n");
      break;
    case CmdType::Rgd:
      modoCadastroBLE = false;
      ble_send("$RGM:0\n");
      break;

    // --- Configuracoes avancadas ---
    case CmdType::AcgQuery:
      sendAdvCfg();
      break;

    // --- Ganhos da ancora (ajuste fino; valores x10) ---
    case CmdType::ApgQuery:
      sendAnchorGains();
      break;
    case CmdType::Apk:
    case CmdType::Api:
    case CmdType::Apd:
    case CmdType::Apr:
      setAnchorGain(c.type, c.arg);
      break;
    case CmdType::Cat:
      calibTimeSeg = clampv((int)c.arg, 1, 10);
      settings_set_i32("calibTimeSeg", calibTimeSeg);
      sendAdvCfg();
      break;
    case CmdType::Cap:
      calibPwmGiro = clampv((int)c.arg, 100, 200);
      settings_set_i32("calibPwmGiro", calibPwmGiro);
      sendAdvCfg();
      break;
    case CmdType::Gup:
      usoPwmGiro = clampv((int)c.arg, 100, 255);
      settings_set_i32("usoPwmGiro", usoPwmGiro);
      sendAdvCfg();
      break;
    case CmdType::Inc:
      aceleracaoIncremento = clampv((int)c.arg, 2, 20);
      settings_set_i32("aceInc", aceleracaoIncremento);
      sendAdvCfg();
      break;

    // --- Aponta norte (calibracao): gira para 0 graus, PWM 120, histerese 5 ---
    case CmdType::Apn:
      if (!bussolaPronta()) break;
      apontaNorteMode = true;
      steerConfigure(SteerMode::PointNorth);
      anchorMode = false;
      northMode  = false;
      giroDir = false; giroEsq = false;
      motorWrite(Out::Left, 0); motorWrite(Out::Right, 0);
      break;
    case CmdType::ApnOff:
      apontaNorteMode = false;
      motorWrite(Out::Left, 0); motorWrite(Out::Right, 0);
      break;

    default:
      break;
  }
}

// ================= PACOTE NRF =================
// Layout (18 bytes ASCII): [0..8] botoes '0'/'1', [9..11] bateria %, [12..16] ID
static void handleNrfPacket(const uint8_t* raw) {
  uint32_t now = millis();
  if (calibrando || (int32_t)(nrfLockUntil - now) > 0) return;

  const char* text = (const char*)raw;
  char idStr[6];  memcpy(idStr, &text[12], 5); idStr[5] = '\0';
  uint32_t controlID = (uint32_t)atoi(idStr);
  char batStr[4]; memcpy(batStr, &text[9], 3); batStr[3] = '\0';
  int8_t batPerc = (int8_t)atoi(batStr);

  ESP_LOGD(TAG, "NRF ID=%05u autorizado=%d", (unsigned)controlID, controleAutorizado(controlID));

  if (modoCadastro || modoCadastroBLE) {
    auto finalizarCadastro = [&](bool remoteRegistered) {
      modoCadastro    = false;
      modoCadastroBLE = false;
      if (ble_connected()) {
        ble_send("$RGM:0\n");
        if (remoteRegistered) sendRemMsg();
      }
    };
    for (uint8_t slot = 0; slot < MAX_CONTROLES; slot++) {
      if (text[slot] == '1') {
        salvarControle(slot, controlID);
        finalizarCadastro(true);
        nrfLock(2000);
        return;
      }
    }
    if (text[5] == '1' && text[6] == '1') {
      iniciarCalibracao();
      finalizarCadastro(false);
      nrfLock(2000);
      return;
    }
    if (text[7] == '1') {
      if (bussolaPronta()) { apontaNorteMode = true; steerConfigure(SteerMode::PointNorth); }
      finalizarCadastro(false);
      nrfLock(2000);
      return;
    }
    return;
  }

  if (!controleAutorizado(controlID)) {
    buzzer_play(PAT_NAO_AUTORIZ, 3);
    nrfLock(300);
    return;
  }

  // Atualiza bateria do controle e notifica o app se mudou
  for (int s = 0; s < MAX_CONTROLES; s++) {
    if (controlesMem[s] == controlID) {
      if (remoteBatt[s] != batPerc) {
        remoteBatt[s] = batPerc;
        if (ble_connected()) sendRemMsg();
      }
      break;
    }
  }

  const char* cmd = text;
  buzzer_beep(BEEP_CMD);   // confirmacao de recebimento

  // ANCORA ATIVA: qualquer botao desativa
  if (anchorMode) {
    for (int b = 0; b < 9; b++) {
      if (cmd[b] == '1') { desativarAncora(); nrfLock(300); break; }
    }
    return;
  }

  // NORTE ATIVO: motor/acel funcionam; giro/up/down/ancora/norte desativam
  if (northMode) {
    if (cmd[8] == '1') { ativarAncora(); nrfLock(300); return; }
    if (cmd[7] == '1' || cmd[1] == '1' || cmd[2] == '1' || cmd[5] == '1' || cmd[6] == '1') {
      desativarNorte(); nrfLock(300); return;
    }
    if (cmd[3] == '1' && aceleracao < 255) {
      aceleracao = aceleracao + aceleracaoIncremento < 255 ? aceleracao + aceleracaoIncremento : 255;
      if (aceleracao < pwmHeliceMin) aceleracao = pwmHeliceMin;
      motorLigado = true; motorRampAtiva = false; motorWrite(Out::Throttle, aceleracao);
    }
    if (cmd[4] == '1' && aceleracao > pwmHeliceMin) {
      aceleracao = aceleracao - aceleracaoIncremento > pwmHeliceMin ? aceleracao - aceleracaoIncremento : pwmHeliceMin;
      if (motorLigado) { motorRampAtiva = false; motorWrite(Out::Throttle, aceleracao); }
    }
    if (cmd[0] == '1') {
      if (motorLigado) desligarMotor(); else ligarMotor();
    }
    return;
  }

  // MODO NORMAL
  if (cmd[8] == '1') { ativarAncora(); nrfLock(300); return; }
  if (cmd[7] == '1') { ativarNorte();  nrfLock(300); return; }
  if (cmd[0] == '1') {
    if (motorLigado) desligarMotor(); else ligarMotor();
  }
  if (cmd[3] == '1' && aceleracao < 255) {
    aceleracao = aceleracao + aceleracaoIncremento < 255 ? aceleracao + aceleracaoIncremento : 255;
    if (aceleracao < pwmHeliceMin) aceleracao = pwmHeliceMin;
    motorLigado = true; motorRampAtiva = false; motorWrite(Out::Throttle, aceleracao);
  }
  if (cmd[4] == '1' && aceleracao > pwmHeliceMin) {
    aceleracao = aceleracao - aceleracaoIncremento > pwmHeliceMin ? aceleracao - aceleracaoIncremento : pwmHeliceMin;
    motorLigado = true; motorRampAtiva = false; motorWrite(Out::Throttle, aceleracao);
  }
  if (cmd[1] == '1')      { motorWrite(Out::Left, usoPwmGiro); motorWrite(Out::Right, 0); tempoLigadoGiro = now; }
  else if (cmd[2] == '1') { motorWrite(Out::Right, usoPwmGiro); motorWrite(Out::Left, 0); tempoLigadoGiro = now; }
  else if (!giroDir && !giroEsq) { motorWrite(Out::Left, 0); motorWrite(Out::Right, 0); tempoLigadoGiro = now; }
  if (cmd[5] == '1')      { relayUp(true);  relayDown(false); tempoLigadoUpDown = now; }
  else if (cmd[6] == '1') { relayUp(false); relayDown(true);  tempoLigadoUpDown = now; }
  else if (!upAtivo && !downAtivo) { relayUp(false); relayDown(false); tempoLigadoUpDown = now; }
}

static void handleCommand(const Command& c) {
  heading = compass_heading();
  switch (c.type) {
    case CmdType::NrfPacket:
      handleNrfPacket(c.data);
      break;
    case CmdType::BleConnected:
      pendingHmnNotify = true;           // envia HMN/VER/BAT apos 500 ms (aguarda subscribe)
      hmnNotifyTime    = millis();
      break;
    case CmdType::BleDisconnected:
      if (!calibrando) { pararGiro(); pararUpDown(); }
      break;
    default:
      handleBleCmd(c);
      break;
  }
}

// ================= ANCORA (50 Hz) =================
static void anchorCycle(uint32_t now) {
  GpsData g = gps_get();
  if (g.seq != lastAnchorSeq) {
    lastAnchorSeq = g.seq;
    anchor_gps_update(g, now);
  }
  AnchorOutput o = anchor_step(thrustHeading(), steer.active, now);
  pwmComHeading = o.throttle;
  motorWrite(Out::Throttle, o.throttle);
  if (o.turn) steerTo(o.turnErr, now);
  else        steerStop();
}

// ================= MODO NORTE (50 Hz) =================
static void northCycle(uint32_t now) {
  steerTo(wrap180(northHeadingTarget - heading), now);
}

// ================= APONTA NORTE =================
static void apontaNorteCycle(uint32_t now) {
  steerTo(wrap180(0.0f - heading), now);
}

// Avisa (bipe + app) quando o motor de giro trava e quando volta
static void checkSteerStall() {
  if (steer.stalled != steerStalledPrev) {
    steerStalledPrev = steer.stalled;
    if (steer.stalled) {
      ESP_LOGW(TAG, "MOTOR DE GIRO TRAVADO — giro cortado, nova tentativa em 5 s");
      buzzer_play(PAT_GIRO_TRAVADO, 2);
    }
    ble_sendf("$GTV:%d\n", steer.stalled ? 1 : 0);
  }
}

static void publishSnapshot() {
  ControlSnapshot s;
  s.anchorMode      = anchorMode;
  s.northMode       = northMode;
  s.motorLigado     = motorLigado;
  s.heading         = heading;
  AnchorStatus a = anchor_status();
  s.distancia       = a.distance;
  s.bearingFiltered = a.bearing;
  s.pwmComHeading   = pwmComHeading;
  portENTER_CRITICAL(&s_snapMux);
  s_snap = s;
  portEXIT_CRITICAL(&s_snapMux);
}

ControlSnapshot control_snapshot() {
  portENTER_CRITICAL(&s_snapMux);
  ControlSnapshot s = s_snap;
  portEXIT_CRITICAL(&s_snapMux);
  return s;
}

uint32_t control_cycles() { return s_cycles.load(); }

// ================= CICLO PERIODICO (20 ms) =================
static void controlStep() {
  uint32_t now = millis();
  heading = compass_heading();

  // --- Notificacao de configuracao apos conexao (aguarda 500 ms o subscribe) ---
  if (pendingHmnNotify && ble_connected() && (now - hmnNotifyTime) > 500) {
    pendingHmnNotify = false;
    sendHmn();
    sendVer();
    battery_send();
    sendBussolaEstado();
  }

  if (calibrando) {
    stepCalibracao();
    return;
  }

  // --- Monitor da bussola: avisa mudancas e para os modos automaticos ---
  int be = bussolaEstado();
  if (be != bussolaEstadoPrev) {
    if (bussolaEstadoPrev != -1) sendBussolaEstado();
    if (be == 2 && (anchorMode || northMode || apontaNorteMode)) {
      ESP_LOGW(TAG, "Bussola invalida — modos automaticos desligados por seguranca");
      if (anchorMode) resetAnchorState();
      if (northMode)  { northMode = false; if (motorLigado) motorWrite(Out::Throttle, 0); }
      apontaNorteMode = false;
      steerStop();
      buzzer_play(PAT_BUSSOLA_ERRO, 3);
    }
    bussolaEstadoPrev = be;
  }

  // --- Janela de cadastro NRF: 1 s apos o boot ---
  if (modoCadastro && now - bootTime > cadastroTimeout) modoCadastro = false;

  // --- Timeouts hold NRF: so agem se o BLE nao estiver controlando o mesmo atuador ---
  if (!anchorMode && !northMode && !upAtivo && !downAtivo && (now - tempoLigadoUpDown) > 150) {
    relayUp(false); relayDown(false); tempoLigadoUpDown = now;
  }
  if (!anchorMode && !northMode && !apontaNorteMode && !giroDir && !giroEsq &&
      (now - tempoLigadoGiro) > 150) {
    motorWrite(Out::Left, 0); motorWrite(Out::Right, 0); tempoLigadoGiro = now;
  }

  // --- Rampa de aceleracao (religamento manual do motor) ---
  if (motorRampAtiva) {
    if (anchorMode) {
      motorRampAtiva = false;   // ancora assume o acelerador
    } else {
      uint32_t rampElapsed = now - motorRampStart;
      if (rampElapsed >= motorRampDuracao) {
        motorWrite(Out::Throttle, motorRampAlvo);
        motorRampAtiva = false;
      } else {
        motorWrite(Out::Throttle, (int)((int64_t)motorRampAlvo * rampElapsed / motorRampDuracao));
      }
    }
  }

  // --- Timeouts hold BLE (seguranca) ---
  if ((giroDir || giroEsq) && (now - lastGiroCmdTime) > holdTimeout) pararGiro();
  if ((upAtivo || downAtivo) && (now - lastUpDownCmdTime) > holdTimeout) pararUpDown();

  // --- Ancora ---
  if (anchorMode) anchorCycle(now);

  // --- Modo norte ---
  if (northMode) northCycle(now);

  // --- Aponta norte ---
  if (apontaNorteMode && !anchorMode && !northMode) apontaNorteCycle(now);

  // Nenhum modo automatico usando o giro: libera o controle
  if (!anchorMode && !northMode && !apontaNorteMode && steer.active) steer.stop();
  checkSteerStall();
}

static void control_task(void*) {
  esp_task_wdt_add(nullptr);
  QueueHandle_t q = commands_queue();

  buzzer_play(PAT_BOOT, 4);
  bootTime = millis();             // janela de cadastro NRF: 1 s a partir daqui
  tempoLigadoGiro = tempoLigadoUpDown = bootTime;

  uint32_t next = millis();
  for (;;) {
    // Espera comando ate o proximo ciclo: comandos sao tratados na hora,
    // mas o ciclo de 20 ms nunca e adiado por uma rajada de comandos.
    int32_t wait = (int32_t)(next - millis());
    if (wait > 0) {
      Command c;
      if (xQueueReceive(q, &c, pdMS_TO_TICKS(wait)) == pdTRUE) {
        handleCommand(c);
        publishSnapshot();
      }
      continue;
    }
    controlStep();
    publishSnapshot();
    s_cycles++;
    esp_task_wdt_reset();

    next += CONTROL_PERIOD_MS;
    if ((int32_t)(millis() - next) > 5 * CONTROL_PERIOD_MS) next = millis() + CONTROL_PERIOD_MS;
  }
}

void control_start(const Settings& s) {
  pwmHeliceMin         = s.pwmHelMin;
  pwmMotorOff          = s.pwmMotorOff;
  headingOffset        = s.hdgOff;
  calibTimeSeg         = s.calibTimeSeg;
  calibPwmGiro         = s.calibPwmGiro;
  usoPwmGiro           = s.usoPwmGiro;
  aceleracaoIncremento = s.aceInc;
  for (int i = 0; i < MAX_CONTROLES; i++) controlesMem[i] = s.ctrl[i];
  AnchorGains ag;
  ag.kp = s.ancKp10 / 10.0f;
  ag.ki = s.ancKi10 / 10.0f;
  ag.kd = s.ancKd10 / 10.0f;
  anchor_set_gains(ag);
  bussolaCalibrada = s.compCalib;
  steer.p.pwmStart = GIRO_PWM_START;
  steer.p.pwmMax   = GIRO_PWM_MAX;
  steer.reset();

  xTaskCreatePinnedToCore(control_task, "control", STACK_CONTROL, nullptr,
                          PRIO_CONTROL, nullptr, CORE_CTRL);
}
