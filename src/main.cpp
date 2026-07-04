// ================= DEFINES =================
#define USE_NRF     // Descomente para ativar radio NRF24L01
#define LOG_ENABLE    // Habilita debug via Serial
#define FIRMWARE_VERSION "1.1.25"
#define USE_BUZZER  // Descomente para ativar buzzer fisico

// ================= LIBS =================
#include <Arduino.h>
#include <Wire.h>
#include <Preferences.h>
#include <TinyGPS++.h>
#include <HMC5883L.h>
#include <NimBLEDevice.h>
#include <Update.h>
#ifdef USE_NRF
  #include <SPI.h>
  #include <nRF24L01.h>
  #include <RF24.h>
#endif

// ================= BLE UUIDs =================
#define BLE_SVC_UUID "0000ffe0-0000-1000-8000-00805f9b34fb"
#define BLE_CHR_UUID "0000ffe1-0000-1000-8000-00805f9b34fb"
#define BLE_OTA_UUID "0000ffe2-0000-1000-8000-00805f9b34fb"

// ================= PINOS — ESP32 DevKit Classic =================
const int left       = 2;    // PWM giro esquerda  (LEDC)
const int right      = 4;    // PWM giro direita   (LEDC)
const int acelerador = 33;   // PWM helice         (LEDC)
const int pinUp      = 12;   // Subir (digital HIGH=ativo) ⚠️ strapping pin: sem pull-up externo
const int pinDown    = 13;   // Descer (digital HIGH=ativo)
#define GPS_RX_PIN   16
#define GPS_TX_PIN   17
#define I2C_SDA_PIN  21
#define I2C_SCL_PIN  22
#ifdef USE_BUZZER
  const int buz = 27;        // Buzzer placeholder — ajuste o pino conforme hardware
#endif

#ifdef USE_NRF
  #define NRF_CE_PIN   14    // CE
  #define NRF_CSN_PIN  5    // CSN / SS
  #define NRF_SCK_PIN  18    // VSPI SCK
  #define NRF_MISO_PIN 19    // VSPI MISO
  #define NRF_MOSI_PIN 23    // VSPI MOSI
#endif

// ================= LEDC (ESP32 v2.x) =================
#define LEDC_CH_LEFT  0
#define LEDC_CH_RIGHT 1
#define LEDC_CH_ACEL  2

inline void motorWrite(int pin, int val) {
  if      (pin == left)  ledcWrite(LEDC_CH_LEFT,  val);
  else if (pin == right) ledcWrite(LEDC_CH_RIGHT, val);
  else                   ledcWrite(LEDC_CH_ACEL,  val);
}

// ================= HARDWARE CONDICIONAL =================
#ifdef USE_NRF
  SPIClass vspiNrf(VSPI);
  RF24 radio(NRF_CE_PIN, NRF_CSN_PIN);
  const byte address[6] = "00001";
  #define MAX_CONTROLES 5
  uint32_t controlesMem[MAX_CONTROLES];
  unsigned long bootTime;
  bool modoCadastro = true;
  const unsigned long cadastroTimeout = 1500;
  long tempoLigadoGiro   = 0;
  long tempoLigadoUpDown = 0;
#else
  unsigned long lastBtnPress     = 0;
  const unsigned long debounceMs = 400;
#endif

// ================= OBJETOS =================
TinyGPSPlus gps;
HMC5883L    compass;
Preferences prefs;

// ================= BLE =================
NimBLECharacteristic* pBleChar    = nullptr;
bool                  bleConnected = false;
bool                  pendingHmnNotify = false;
unsigned long         hmnNotifyTime   = 0;

NimBLECharacteristic* pOtaChar = nullptr;
bool otaActive = false;
size_t otaExpectedSize = 0;
size_t otaBytesReceived = 0;

// ================= ESTADOS =================
bool anchorMode  = false;
bool northMode   = false;
bool motorLigado = false;

// ================= ANCORA =================
double anchorLat = 0;
double anchorLon = 0;
const double anchorStopDistance  = 1.0;
const double anchorStartDistance = 1.5;
const double giroMinDist         = 1.5;
double distancia       = 0;
int    pwmComHeading   = 0;
bool   apontaNorteMode = false;
double bearingFiltered = 0;
bool   bearingReady    = false;
double lastDist        = -1;
double driftRate       = 0.0;
double anchorHeadError = 0.0;
int    pwmHeliceMin    = 0;    // carregado da NVS no boot; default 0
int    pwmMotorOff     = 0;    // pwmHeliceMin - 5: pre-carga no ESC sem girar (manual desligado)
const int pwmRampStep  = 20;
int       pwmRampAtual = 0;
unsigned long anchorStartTime = 0;

// ================= HEADING =================
float heading           = 0;
long  lastCompassReaded = 0;
long  updateGiro        = 0;
#ifdef USE_BUZZER
  long buzzerLast  = 10;
  bool buzzerAtivo = false;
#endif
const double headingDeadzone = 8.0;
float northHeadingTarget     = 0;

// ================= PID DISTANCIA =================
double Kp_dist = 22.0, Ki_dist = 0.3, Kd_dist = 3.0;
double distIntegral = 0, lastDistError = 0;
const int pwmMax = 255;
double pwmFiltered = 0;

// ================= PID HEADING (modo norte) =================
double Kp_head = 4.0, Ki_head = 0.02, Kd_head = 1.5;
double headIntegral = 0, lastHeadError = 0;

// ================= PID GIRO =================
double Kp_giro = 3.0, Ki_giro = 0.1, Kd_giro = 0.0;
double giroIntegral = 0, lastGiroError = 0;
const int    pwmGiroMin  = 150;
const int    pwmGiroMax  = 240;
const double zonaForte   = 220.0;
const int    pwmFinoMax  = 150;
const int    pwmForteMin = 220;
unsigned long lastGiroTime = 0;

// ================= CONTROLE =================
int           aceleracao  = 0;
unsigned long lastGPSTime = 0;

// ================= HOLD BLE =================
bool          giroDir   = false;
bool          giroEsq   = false;
bool          upAtivo   = false;
bool          downAtivo = false;
unsigned long lastGiroCmdTime   = 0;
unsigned long lastUpDownCmdTime = 0;
const unsigned long holdTimeout = 150;  // ms sem novo comando para parar

// ================= TELEMETRIA / BUFFER RX =================
unsigned long lastTelemetryTime = 0;
String        bleCmdBuffer      = "";

// ================= DEBUG =================
#ifdef LOG_ENABLE
  unsigned long lastStatusPrint = 0;
#endif

// ================= BUSSOLA =================
float compassXOffset = 0;
float compassYOffset = 0;

// ================= KALMAN HEADING =================
struct HeadingKalman {
  double Q = 2.0, R = 3.0, P = 10.0, K = 0.0, x = 0.0;
  bool initialized = false;
  double update(double m) {
    if (!initialized) { x = m; initialized = true; return x; }
    P += Q;
    double innov = m - x;
    if (innov >  180.0) innov -= 360.0;
    if (innov < -180.0) innov += 360.0;
    K = P / (P + R);
    x += K * innov;
    P *= (1.0 - K);
    if (x <   0.0) x += 360.0;
    if (x >= 360.0) x -= 360.0;
    return x;
  }
  void reset() { P = 10.0; initialized = false; }
};
HeadingKalman kfHeading;

// ================= NVS CONTROLES (USE_NRF) =================
#ifdef USE_NRF
void carregarControlesNVS() {
  prefs.begin("barco", true);
  for (int i = 0; i < MAX_CONTROLES; i++) {
    String key = "ctrl" + String(i);
    controlesMem[i] = prefs.getUInt(key.c_str(), 0);
  }
  prefs.end();
}
bool controleAutorizado(uint32_t id) {
  for (int i = 0; i < MAX_CONTROLES; i++)
    if (controlesMem[i] == id && id != 0) return true;
  return false;
}
void salvarControle(uint8_t slot, uint32_t id) {
  controlesMem[slot] = id;
  prefs.begin("barco", false);
  String key = "ctrl" + String(slot);
  prefs.putUInt(key.c_str(), id);
  prefs.end();
  #ifdef USE_BUZZER
    for (int i = 0; i <= slot; i++) {
      digitalWrite(buz, HIGH); delay(300); digitalWrite(buz, LOW); delay(200);
    }
  #endif
}
#endif

// ================= BUSSOLA — leitura direta HMC5883L =================
// Evita readRegister8() bloqueante (while(!Wire.available()){}) da biblioteca
static bool hmc5883l_readRaw(float &fx, float &fy) {
  Wire.beginTransmission(0x1E);
  Wire.write(0x03);
  if (Wire.endTransmission(false) != 0) return false;
  uint8_t n = Wire.requestFrom((uint8_t)0x1E, (uint8_t)6, (uint8_t)true);
  if (n < 6) return false;
  int16_t rx = ((int16_t)Wire.read() << 8) | Wire.read();
  Wire.read(); Wire.read();  // Z ignorado
  int16_t ry = ((int16_t)Wire.read() << 8) | Wire.read();
  fx = rx * 0.92f;
  fy = ry * 0.92f;
  return true;
}

void carregarCalibracaoBussola() {
  prefs.begin("barco", true);
  bool hasCalib = prefs.getBool("compCalib", false);
  if (hasCalib) {
    compassXOffset = prefs.getFloat("compXoff", 0.0f);
    compassYOffset = prefs.getFloat("compYoff", 0.0f);
    #ifdef LOG_ENABLE
      Serial.print(F("  Bussola NVS: Xoff=")); Serial.print(compassXOffset, 2);
      Serial.print(F(" Yoff="));               Serial.println(compassYOffset, 2);
    #endif
  } else {
    #ifdef LOG_ENABLE
      Serial.println(F("  Bussola: SEM calibracao salva"));
    #endif
  }
  prefs.end();
}

void calibrarBussola() {
  #ifdef LOG_ENABLE
    Serial.println(F("\n[CALIBRACAO] Iniciando — gira motor 360 em cada sentido"));
  #endif
  float minX = 9999, maxX = -9999, minY = 9999, maxY = -9999;
  #ifdef USE_BUZZER
    digitalWrite(buz, HIGH);
  #endif
  long t0 = millis();
  motorWrite(left, 140); motorWrite(right, 0);
  while (millis() - t0 < 9500) {
    float mx, my;
    if (hmc5883l_readRaw(mx, my)) {
      minX = min(minX, mx); maxX = max(maxX, mx);
      minY = min(minY, my); maxY = max(maxY, my);
    }
    delay(50);
  }
  motorWrite(left, 0); motorWrite(right, 0);
  #ifdef USE_BUZZER
    digitalWrite(buz, LOW); delay(1000);
    digitalWrite(buz, HIGH);
  #endif
  t0 = millis();
  motorWrite(left, 0); motorWrite(right, 140);
  while (millis() - t0 < 9500) {
    float mx, my;
    if (hmc5883l_readRaw(mx, my)) {
      minX = min(minX, mx); maxX = max(maxX, mx);
      minY = min(minY, my); maxY = max(maxY, my);
    }
    delay(50);
  }
  motorWrite(left, 0); motorWrite(right, 0);
  #ifdef USE_BUZZER
    digitalWrite(buz, LOW); delay(1000);
    for (int i = 0; i < 3; i++) {
      digitalWrite(buz, HIGH); delay(200); digitalWrite(buz, LOW); delay(200);
    }
  #endif
  compassXOffset = (maxX + minX) / 2.0f;
  compassYOffset = (maxY + minY) / 2.0f;
  prefs.begin("barco", false);
  prefs.putFloat("compXoff", compassXOffset);
  prefs.putFloat("compYoff", compassYOffset);
  prefs.putBool("compCalib", true);
  prefs.end();
  #ifdef LOG_ENABLE
    Serial.print(F("[CALIBRACAO] OK — Xoff=")); Serial.print(compassXOffset, 2);
    Serial.print(F(" Yoff=")); Serial.print(compassYOffset, 2);
    Serial.println(F(" (salvo NVS)"));
  #endif
}

float readCompassCalibrado() {
  float nx, ny;
  if (!hmc5883l_readRaw(nx, ny)) return heading;
  float x = nx - compassXOffset;
  float y = ny - compassYOffset;
  float h = atan2(y, x) * 180.0f / PI;
  if (h < 0) h += 360.0f;
  return h;
}

// ================= CALCULO GPS =================
double getDistance(double lat1, double lon1, double lat2, double lon2) {
  const double R = 6371000.0;
  double dLat = radians(lat2 - lat1);
  double dLon = radians(lon2 - lon1);
  double a = sin(dLat/2)*sin(dLat/2) +
             cos(radians(lat1))*cos(radians(lat2))*sin(dLon/2)*sin(dLon/2);
  return R * 2.0 * atan2(sqrt(a), sqrt(1.0 - a));
}

double getBearing(double lat1, double lon1, double lat2, double lon2) {
  double dLon = radians(lon2 - lon1);
  double y    = sin(dLon) * cos(radians(lat2));
  double x    = cos(radians(lat1)) * sin(radians(lat2)) -
                sin(radians(lat1)) * cos(radians(lat2)) * cos(dLon);
  double b = atan2(y, x) * 180.0 / PI;
  if (b < 0) b += 360.0;
  return b;
}

// ================= BUZZER =================
#ifdef USE_BUZZER
void beep(int) {
  digitalWrite(buz, HIGH);
  buzzerLast  = millis();
  buzzerAtivo = true;
}
#endif

// ================= PID GIRO =================
int calcPidGiro(double erro) {
  unsigned long tg = millis();
  double dt_g   = constrain((tg - lastGiroTime) / 1000.0, 0.01, 0.5);
  lastGiroTime  = tg;
  giroIntegral += erro * dt_g;
  giroIntegral  = constrain(giroIntegral, -300.0, 300.0);
  double deriv  = (erro - lastGiroError) / dt_g;
  lastGiroError = erro;
  double pidOut = Kp_giro * erro + Ki_giro * giroIntegral + Kd_giro * deriv;
  int piso = (abs(erro) >= zonaForte) ? pwmForteMin : pwmGiroMin;
  int teto = (abs(erro) >= zonaForte) ? pwmGiroMax  : pwmFinoMax;
  return constrain((int)abs(pidOut), piso, teto);
}

// ================= HELPERS HOLD =================
void pararGiro() {
  giroDir = false; giroEsq = false;
  motorWrite(left, 0); motorWrite(right, 0);
}

void pararUpDown() {
  upAtivo = false; downAtivo = false;
  digitalWrite(pinUp, LOW); digitalWrite(pinDown, LOW);
}

// ================= HELPER BLE SEND =================
void bleSend(const String& s) {
  if (bleConnected && pBleChar) {
    pBleChar->setValue((uint8_t*)s.c_str(), s.length());
    pBleChar->notify();
  }
}

// ================= ATIVAR ANCORA =================
void ativarAncora() {
  double lat = gps.location.lat();
  double lon = gps.location.lng();
  bool gpsOk = gps.location.isValid()
               && gps.location.age() < 2000
               && (lat != 0.0 || lon != 0.0);
  if (gpsOk) {
    anchorMode      = true;
    anchorLat       = lat;
    anchorLon       = lon;
    distIntegral    = 0;
    lastDistError   = 0;
    lastGPSTime     = millis();
    pwmFiltered     = 0;
    pwmComHeading   = 0;
    pwmRampAtual    = 0;
    giroIntegral    = 0;
    lastGiroError   = 0;
    lastGiroTime    = millis();
    updateGiro      = millis();
    kfHeading.reset();
    bearingReady    = false;
    lastDist        = -1;
    driftRate       = 0.0;
    anchorHeadError = 0.0;
    distancia       = 0.0;
    anchorStartTime = millis();
    #ifdef LOG_ENABLE
      Serial.println(F("\n========== ANCORA ATIVADA =========="));
      Serial.print(F("  GPS age : ")); Serial.print(gps.location.age());
      Serial.print(F(" ms  |  Sats: ")); Serial.println(gps.satellites.value());
      Serial.println(F("=====================================\n"));
    #endif
    #ifdef USE_BUZZER
      digitalWrite(buz, HIGH); delay(300);
      digitalWrite(buz, LOW);  delay(100);
      digitalWrite(buz, HIGH); delay(300);
      digitalWrite(buz, LOW);
    #endif
  } else {
    #ifdef LOG_ENABLE
      Serial.println(F("[ERRO] GPS invalido - ancora NAO ativada"));
      Serial.print(F("  isValid: ")); Serial.println(gps.location.isValid() ? F("sim") : F("nao"));
      Serial.print(F("  age    : ")); Serial.print(gps.location.age()); Serial.println(F(" ms"));
    #endif
    #ifdef USE_BUZZER
      for (int i = 0; i < 3; i++) {
        digitalWrite(buz, HIGH); delay(80); digitalWrite(buz, LOW); delay(80);
      }
    #endif
  }
}

// ================= DESATIVAR ANCORA =================
void desativarAncora() {
  #ifdef LOG_ENABLE
    float elapsed = (millis() - anchorStartTime) / 1000.0f;
    Serial.println(F("\n============================================"));
    Serial.println(F("            ANCORA DESATIVADA"));
    Serial.print(F("  Tempo ativo: ")); Serial.print(elapsed, 1); Serial.println(F(" s"));
    Serial.println(F("============================================\n"));
  #endif
  anchorMode      = false;
  distIntegral    = 0;
  lastDistError   = 0;
  pwmFiltered     = 0;
  pwmComHeading   = 0;
  pwmRampAtual    = 0;
  giroIntegral    = 0;
  lastGiroError   = 0;
  bearingReady    = false;
  lastDist        = -1;
  driftRate       = 0.0;
  anchorHeadError = 0.0;
  motorWrite(acelerador, 0);
  motorWrite(left,  0);
  motorWrite(right, 0);
  #ifdef USE_BUZZER
    digitalWrite(buz, HIGH); delay(700); digitalWrite(buz, LOW);
  #endif
}

// ================= PROCESSAMENTO DE COMANDOS BLE =================
void processBlecmd(const String& cmd) {
  // --- Ancora ---
  if (cmd == "$ANC") {
    if (!anchorMode) ativarAncora(); else desativarAncora();
  }
  // --- Norte ---
  else if (cmd == "$NRT") {
    northMode = !northMode;
    anchorMode = false;
    if (northMode) {
      northHeadingTarget = heading;
      giroIntegral = 0; lastGiroError = 0; lastGiroTime = millis();
      #ifdef USE_BUZZER
        digitalWrite(buz, HIGH); delay(300); digitalWrite(buz, LOW);
      #endif
    } else {
      giroIntegral = 0; lastGiroError = 0; headIntegral = 0; lastHeadError = 0;
      if (motorLigado) motorWrite(acelerador, 0);
      #ifdef USE_BUZZER
        digitalWrite(buz, HIGH); delay(700); digitalWrite(buz, LOW);
      #endif
    }
  }
  // --- Motor ON/OFF ---
  else if (cmd == "$MOT") {
    motorLigado = !motorLigado;
    if (motorLigado) {
      if (aceleracao < pwmHeliceMin) aceleracao = pwmHeliceMin;
      motorWrite(acelerador, aceleracao);
    } else {
      motorWrite(acelerador, pwmMotorOff);
    }
    #ifdef USE_BUZZER
    if (buzzerAtivo && (millis() - buzzerLast) > 10) {
      digitalWrite(buz, LOW);
      buzzerAtivo = false;
    }
  #endif

  }
  // --- Aceleracao ---
  else if (cmd == "$ACE+") {
    aceleracao = constrain(aceleracao + 5, 0, 255);
    if (motorLigado) motorWrite(acelerador, aceleracao);
    #ifdef USE_BUZZER
    if (buzzerAtivo && (millis() - buzzerLast) > 10) {
      digitalWrite(buz, LOW);
      buzzerAtivo = false;
    }
  #endif
  }
  else if (cmd == "$ACE-") {
    int minAcel = motorLigado ? pwmHeliceMin : 0;
    aceleracao = constrain(aceleracao - 5, minAcel, 255);
    if (motorLigado) motorWrite(acelerador, aceleracao);
    #ifdef USE_BUZZER
    if (buzzerAtivo && (millis() - buzzerLast) > 10) {
      digitalWrite(buz, LOW);
      buzzerAtivo = false;
    }
  #endif
  }
  // --- Giro direita ---
  else if (cmd == "$GTR+") {
    if (!anchorMode) {
      giroDir = true; giroEsq = false;
      motorWrite(right, 230); motorWrite(left, 0);
      lastGiroCmdTime = millis();
      #ifdef USE_BUZZER
    if (buzzerAtivo && (millis() - buzzerLast) > 10) {
      digitalWrite(buz, LOW);
      buzzerAtivo = false;
    }
  #endif
    }
  }
  else if (cmd == "$GTR-") {
    giroDir = false;
    if (!giroEsq) { motorWrite(right, 0); motorWrite(left, 0); }
  }
  // --- Giro esquerda ---
  else if (cmd == "$GTL+") {
    if (!anchorMode) {
      giroEsq = true; giroDir = false;
      motorWrite(left, 230); motorWrite(right, 0);
      lastGiroCmdTime = millis();
      #ifdef USE_BUZZER
    if (buzzerAtivo && (millis() - buzzerLast) > 10) {
      digitalWrite(buz, LOW);
      buzzerAtivo = false;
    }
  #endif
    }
  }
  else if (cmd == "$GTL-") {
    giroEsq = false;
    if (!giroDir) { motorWrite(left, 0); motorWrite(right, 0); }
  }
  // --- Subir ---
  else if (cmd == "$UPP+") {
    upAtivo = true; downAtivo = false;
    digitalWrite(pinUp, HIGH); digitalWrite(pinDown, LOW);
    lastUpDownCmdTime = millis();
  }
  else if (cmd == "$UPP-") {
    upAtivo = false;
    if (!downAtivo) digitalWrite(pinUp, LOW);
  }
  // --- Descer ---
  else if (cmd == "$DWN+") {
    downAtivo = true; upAtivo = false;
    digitalWrite(pinDown, HIGH); digitalWrite(pinUp, LOW);
    lastUpDownCmdTime = millis();
  }
  else if (cmd == "$DWN-") {
    downAtivo = false;
    if (!upAtivo) digitalWrite(pinDown, LOW);
  }
  // --- PWM Helice Minimo ---
  else if (cmd == "$HMN+") {
    pwmHeliceMin = constrain(pwmHeliceMin + 1, 0, 255);
    pwmMotorOff  = max(0, pwmHeliceMin - 5);
    motorWrite(acelerador, pwmHeliceMin);
    prefs.begin("barco", false);
    prefs.putInt("pwmHelMin",   pwmHeliceMin);
    prefs.putInt("pwmMotorOff", pwmMotorOff);
    prefs.end();
    bleSend("$HMN:" + String(pwmHeliceMin) + "\n");
  }
  else if (cmd == "$HMN-") {
    pwmHeliceMin = constrain(pwmHeliceMin - 1, 0, 255);
    pwmMotorOff  = max(0, pwmHeliceMin - 5);
    motorWrite(acelerador, pwmHeliceMin);
    prefs.begin("barco", false);
    prefs.putInt("pwmHelMin",   pwmHeliceMin);
    prefs.putInt("pwmMotorOff", pwmMotorOff);
    prefs.end();
    bleSend("$HMN:" + String(pwmHeliceMin) + "\n");
  }
  // --- Calibrar bussola ---
  else if (cmd == "$CAL") {
    calibrarBussola();
  }
  // --- Solicitar configuracao atual (app envia apos subscribe para receber HMN e VER) ---
  else if (cmd == "$CFG?") {
    bleSend("$HMN:" + String(pwmHeliceMin) + "\n");
    bleSend("$VER:" + String(FIRMWARE_VERSION) + "\n");
  }
  // --- Aponta Norte: gira para 0° com PWM 120 e histerese 5° (calibracao bussola) ---
  else if (cmd == "$APN") {
    apontaNorteMode = true;
    anchorMode  = false;
    northMode   = false;
    giroDir     = false;
    giroEsq     = false;
    motorWrite(left, 0); motorWrite(right, 0);
  }
  else if (cmd == "$APN-") {
    apontaNorteMode = false;
    motorWrite(left, 0); motorWrite(right, 0);
  }
}

// ================= OTA CALLBACKS =================
class OtaCharCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c) override {
    std::string val = c->getValue();
    if (val.empty()) return;

    // Check for text commands (OTA_START, OTA_END)
    String s = String(val.c_str());
    if (s.startsWith("OTA_START:")) {
      // Format: OTA_START:<size>:<version>
      int colon2 = s.indexOf(':', 10);
      otaExpectedSize = s.substring(10, colon2).toInt();
      String ver = (colon2 > 0) ? s.substring(colon2 + 1) : "?";
      #ifdef LOG_ENABLE
        Serial.printf("[OTA] Start: %u bytes, version %s\n", otaExpectedSize, ver.c_str());
      #endif
      if (!Update.begin(otaExpectedSize, U_FLASH)) {
        String err = "OTA_ERR:begin failed\n";
        pOtaChar->setValue((uint8_t*)err.c_str(), err.length());
        pOtaChar->notify();
        otaActive = false;
        return;
      }
      otaBytesReceived = 0;
      otaActive = true;
      String rdy = "OTA_READY\n";
      pOtaChar->setValue((uint8_t*)rdy.c_str(), rdy.length());
      pOtaChar->notify();
    } else if (s.startsWith("OTA_END")) {
      if (!otaActive) return;
      otaActive = false;
      if (Update.end(true)) {
        String ok = "OTA_OK\n";
        pOtaChar->setValue((uint8_t*)ok.c_str(), ok.length());
        pOtaChar->notify();
        delay(500);
        ESP.restart();
      } else {
        String err = "OTA_ERR:end failed\n";
        pOtaChar->setValue((uint8_t*)err.c_str(), err.length());
        pOtaChar->notify();
      }
    } else if (otaActive) {
      // Binary data chunk
      size_t written = Update.write((uint8_t*)val.data(), val.size());
      otaBytesReceived += written;
      if (written != val.size()) {
        String err = "OTA_ERR:write failed\n";
        pOtaChar->setValue((uint8_t*)err.c_str(), err.length());
        pOtaChar->notify();
        otaActive = false;
        Update.abort();
        return;
      }
      // Send ACK every 16KB
      if (otaBytesReceived % (16 * 1024) < val.size()) {
        String ack = "OTA_ACK:" + String(otaBytesReceived) + "\n";
        pOtaChar->setValue((uint8_t*)ack.c_str(), ack.length());
        pOtaChar->notify();
        #ifdef LOG_ENABLE
          Serial.printf("[OTA] Progress: %u/%u bytes\n", otaBytesReceived, otaExpectedSize);
        #endif
      }
    }
  }
};

// ================= BLE CALLBACKS =================
class BleServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer*) override {
    bleConnected = true;
    // Envia pwmHeliceMin apos 500ms (aguarda subscribe do app)
    pendingHmnNotify = true;
    hmnNotifyTime    = millis();
  }
  void onDisconnect(NimBLEServer* s) override {
    bleConnected = false;
    pararGiro();
    pararUpDown();
    s->startAdvertising();
  }
};

class BleCharCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c) override {
    std::string val = c->getValue();
    for (size_t i = 0; i < val.length(); i++) {
      char ch = val[i];
      if (ch == '\n') {
        bleCmdBuffer.trim();
        processBlecmd(bleCmdBuffer);
        bleCmdBuffer = "";
      } else if (ch != '\r') {
        bleCmdBuffer += ch;
      }
    }
  }
};

// ================= SETUP =================
void setup() {
  #ifdef LOG_ENABLE
    Serial.begin(115200);
    unsigned long _t = millis();
    while (!Serial && millis() - _t < 3000) delay(10);
    Serial.println();
    Serial.println(F("========================================"));
    Serial.print(F("      MODULO BARCO  —  firmware "));
    Serial.println(F(FIRMWARE_VERSION));
    Serial.println(F("      Plataforma : ESP32 DevKit Classic"));
    #ifdef USE_NRF
      Serial.println(F("      Modo : BLE + RADIO NRF24L01"));
    #else
      Serial.println(F("      Modo : BLE + botao fisico"));
    #endif
    Serial.println(F("========================================"));
    Serial.println(F("Iniciando..."));
  #endif

  // --- NVS: carrega configuracoes persistidas ---
  prefs.begin("barco", true);
  pwmHeliceMin = prefs.getInt("pwmHelMin",   0);
  pwmMotorOff  = prefs.getInt("pwmMotorOff", 0);
  prefs.end();
  #ifdef LOG_ENABLE
    Serial.print(F("  pwmHeliceMin : ")); Serial.print(pwmHeliceMin);
    Serial.print(F("  pwmMotorOff  : ")); Serial.println(pwmMotorOff);
  #endif

  // --- GPS ---
  #ifdef LOG_ENABLE
    Serial.println(F("[1] GPS Serial..."));
  #endif
  Serial2.begin(9600, SERIAL_8N1, GPS_RX_PIN, GPS_TX_PIN);
  delay(500);
  // UBX-CFG-RATE: 250ms = 4Hz
  static const uint8_t ubxRate4Hz[] = {
    0xB5,0x62, 0x06,0x08, 0x06,0x00, 0xFA,0x00, 0x01,0x00, 0x01,0x00, 0x10,0x96
  };
  Serial2.write(ubxRate4Hz, sizeof(ubxRate4Hz));
  // UBX-CFG-CFG: salva na flash do GPS (persiste apos desligar)
  static const uint8_t ubxSave[] = {
    0xB5,0x62, 0x06,0x09, 0x0D,0x00,
    0x00,0x00,0x00,0x00,  // clearMask
    0xFF,0xFF,0x00,0x00,  // saveMask
    0x00,0x00,0x00,0x00,  // loadMask
    0x17,                  // deviceMask
    0x31,0xBF              // checksum
  };
  Serial2.write(ubxSave, sizeof(ubxSave));
  #ifdef LOG_ENABLE
    Serial.println(F("  GPS : rate 4Hz configurado"));
  #endif

  // --- Wire / I2C ---
  #ifdef LOG_ENABLE
    Serial.println(F("[2] Wire / Pinos..."));
  #endif
  Wire.begin(I2C_SDA_PIN, I2C_SCL_PIN);
  Wire.setClock(50000);  // 50kHz — mais tolerante a ruido em ambiente com motor/ESC
  Wire.setTimeout(100);

  // --- Pinos de saida ---
  pinMode(left,       OUTPUT);
  pinMode(right,      OUTPUT);
  pinMode(acelerador, OUTPUT);
  pinMode(pinUp,      OUTPUT);
  pinMode(pinDown,    OUTPUT);
  digitalWrite(pinUp,   LOW);
  digitalWrite(pinDown, LOW);
  #ifdef USE_BUZZER
    pinMode(buz, OUTPUT);
  #endif

  // --- LEDC ---
  ledcSetup(LEDC_CH_LEFT,  5000, 8); ledcAttachPin(left,       LEDC_CH_LEFT);
  ledcSetup(LEDC_CH_RIGHT, 5000, 8); ledcAttachPin(right,      LEDC_CH_RIGHT);
  ledcSetup(LEDC_CH_ACEL,  5000, 8); ledcAttachPin(acelerador, LEDC_CH_ACEL);

  #ifdef LOG_ENABLE
    Serial.println(F("  I2C scan:"));
    for (uint8_t addr = 1; addr < 127; addr++) {
      Wire.beginTransmission(addr);
      if (Wire.endTransmission() == 0) {
        Serial.print(F("    0x"));
        if (addr < 16) Serial.print(F("0"));
        Serial.println(addr, HEX);
      }
    }
  #endif

  // --- NRF24L01 ---
  #ifdef USE_NRF
    #ifdef LOG_ENABLE
      Serial.println(F("[3] NRF24L01 (VSPI CE=14 CSN=15 SCK=18 MISO=19 MOSI=23)..."));
    #endif
    vspiNrf.begin(NRF_SCK_PIN, NRF_MISO_PIN, NRF_MOSI_PIN, NRF_CSN_PIN);
    if (!radio.begin(&vspiNrf)) {
      #ifdef LOG_ENABLE
        Serial.println(F("  NRF24L01 : ** FALHA NA INICIALIZACAO **"));
        Serial.println(F("             Verifique fiacao SPI / alimentacao 3.3V"));
      #endif
    } else {
     // radio.setChannel(76);          // canal RF — deve ser igual ao do transmissor
      radio.setDataRate(RF24_250KBPS);
      radio.setPALevel(RF24_PA_MAX);
      radio.setPayloadSize(18);      // tamanho fixo do pacote do controle
      // Pipe 0 é reservado para TX/ACK — usar pipe 1 para recepção
      radio.openReadingPipe(1, address);
      radio.startListening();
      carregarControlesNVS();
      bootTime = millis();
      #ifdef LOG_ENABLE
        Serial.println(F("  NRF24L01 : OK"));
        Serial.print(F("    isChipConnected : ")); Serial.println(radio.isChipConnected() ? F("sim") : F("NAO"));
        Serial.print(F("    Canal           : ")); Serial.println(radio.getChannel());
        Serial.print(F("    DataRate        : ")); Serial.println(radio.getDataRate() == RF24_250KBPS ? F("250KBPS") : F("outro"));
        Serial.print(F("    PayloadSize     : ")); Serial.println(radio.getPayloadSize());
        Serial.print(F("    Endereco (pipe1): ")); Serial.println((char*)address);
        radio.printDetails();
      #endif
    }
  #endif

  // --- HMC5883L ---
  #ifdef LOG_ENABLE
    Serial.println(F("[4] HMC5883L..."));
  #endif
  Wire.beginTransmission(0x1E);
  bool compassPresent = (Wire.endTransmission() == 0);
  if (compassPresent) {
    // Escrita direta nos registradores — evita readRegister8 bloqueante da biblioteca
    Wire.beginTransmission(0x1E); Wire.write(0x00); Wire.write(0x74); Wire.endTransmission();
    Wire.beginTransmission(0x1E); Wire.write(0x01); Wire.write(0x20); Wire.endTransmission();
    Wire.beginTransmission(0x1E); Wire.write(0x02); Wire.write(0x00); Wire.endTransmission();
    compass.setOffset(0, 0, 0);
    carregarCalibracaoBussola();
    #ifdef LOG_ENABLE
      Serial.println(F("  HMC5883L : OK"));
    #endif
  } else {
    #ifdef LOG_ENABLE
      Serial.print(F("  HMC5883L : NAO ENCONTRADO (SDA=")); Serial.print(I2C_SDA_PIN);
      Serial.print(F(" SCL=")); Serial.print(I2C_SCL_PIN); Serial.println(F(")"));
    #endif
  }

  // --- NimBLE ---
  #ifdef LOG_ENABLE
    Serial.println(F("[5] NimBLE..."));
  #endif
  NimBLEDevice::init("BragaPesca");
  NimBLEServer*  pServer  = NimBLEDevice::createServer();
  pServer->setCallbacks(new BleServerCallbacks());
  NimBLEService* pService = pServer->createService(BLE_SVC_UUID);
  pBleChar = pService->createCharacteristic(
    BLE_CHR_UUID,
    NIMBLE_PROPERTY::READ    |
    NIMBLE_PROPERTY::WRITE   |
    NIMBLE_PROPERTY::NOTIFY  |
    NIMBLE_PROPERTY::WRITE_NR
  );
  pBleChar->setCallbacks(new BleCharCallbacks());
  pOtaChar = pService->createCharacteristic(
    BLE_OTA_UUID,
    NIMBLE_PROPERTY::WRITE   |
    NIMBLE_PROPERTY::WRITE_NR|
    NIMBLE_PROPERTY::NOTIFY
  );
  pOtaChar->setCallbacks(new OtaCharCallbacks());
  pService->start();
  NimBLEAdvertising* pAdv = NimBLEDevice::getAdvertising();
  pAdv->addServiceUUID(BLE_SVC_UUID);
  pAdv->start();
  #ifdef LOG_ENABLE
    Serial.println(F("  NimBLE : advertising 'ModuloBarco'"));
    Serial.println(F("Pronto.\n"));
  #endif

  //#ifdef USE_BUZZER
   // for (int i = 0; i < 5; i++) {
   //   digitalWrite(buz, HIGH); delay(200); digitalWrite(buz, LOW); delay(200);
  //  }
    
  //#endif
}

// ================= LOOP =================
void loop() {

  // --- Bussola Kalman (50ms) ---
  if ((millis() - lastCompassReaded) > 50) {
    heading           = kfHeading.update(readCompassCalibrado());
    lastCompassReaded = millis();
  }

  // --- Buzzer one-shot ---
  #ifdef USE_BUZZER
    if (buzzerAtivo && (millis() - buzzerLast) > 10) {
      digitalWrite(buz, LOW);
      buzzerAtivo = false;
    }
  #endif

  // --- Notificacao HMN apos conexao (aguarda 500ms para subscribe) ---
  if (pendingHmnNotify && bleConnected && (millis() - hmnNotifyTime) > 500) {
    pendingHmnNotify = false;
    bleSend("$HMN:" + String(pwmHeliceMin) + "\n");
    bleSend("$VER:" + String(FIRMWARE_VERSION) + "\n");
  }

  // --- GPS ---
  while (Serial2.available()) gps.encode(Serial2.read());

  // ========================================================
  //              ENTRADA DE COMANDOS
  // ========================================================
  #ifdef USE_NRF
  if (millis() - bootTime > cadastroTimeout) modoCadastro = false;

  #ifdef LOG_ENABLE
  {
    static unsigned long _nrfDbg = 0;
    if (millis() - _nrfDbg > 2000) {
      _nrfDbg = millis();
      Serial.print(F("[NRF] chip="));     Serial.print(radio.isChipConnected() ? F("OK") : F("FALHA"));
      Serial.print(F(" avail="));         Serial.print(radio.available());
      Serial.print(F(" rxMode="));         Serial.print(radio.available() >= 0 ? F("RX") : F("?"));
      Serial.print(F(" modoCadastro="));  Serial.println(modoCadastro);
    }
  }
  #endif

  if (radio.available()) {
    char text[18] = {0};
    radio.read(&text, sizeof(text));
    char idStr[6];
    memcpy(idStr, &text[12], 5); idStr[5] = '\0';
    uint32_t controlID = (uint32_t)atoi(idStr);

    #ifdef LOG_ENABLE
    {
      Serial.print(F("[NRF] PACOTE recebido! ID="));
      Serial.print(controlID);
      Serial.print(F(" bytes=["));
      for (int _i = 0; _i < 18; _i++) {
        Serial.print(text[_i]);
        if (_i < 17) Serial.print(',');
      }
      Serial.print(F("] autorizado="));
      Serial.println(controleAutorizado(controlID) ? F("SIM") : F("NAO (nao cadastrado)"));
    }
    #endif

    if (modoCadastro) {
      if      (text[0]=='1'){ salvarControle(0,controlID); modoCadastro=false; delay(2000); return; }
      else if (text[1]=='1'){ salvarControle(1,controlID); modoCadastro=false; delay(2000); return; }
      else if (text[2]=='1'){ salvarControle(2,controlID); modoCadastro=false; delay(2000); return; }
      else if (text[3]=='1'){ salvarControle(3,controlID); modoCadastro=false; delay(2000); return; }
      else if (text[4]=='1'){ salvarControle(4,controlID); modoCadastro=false; delay(2000); return; }
      else if (text[5]=='1' && text[6]=='1'){ calibrarBussola(); modoCadastro=false; delay(2000); return; }
      else if (text[7]=='1'){
        apontaNorteMode=true; giroIntegral=0; lastGiroError=0; lastGiroTime=millis();
        modoCadastro=false; delay(2000); return;
      }
      return;
    }

    if (!controleAutorizado(controlID)) {
      #ifdef USE_BUZZER
        for (int i=0;i<6;i++){ digitalWrite(buz,HIGH); delay(30); digitalWrite(buz,LOW); delay(30); }
      #endif
      return;
    }

    char *cmd = &text[0];
    #ifdef USE_BUZZER
     //beep(1);
    #endif

    if (cmd[7]=='1' && !northMode) {
      if (!anchorMode) ativarAncora(); else desativarAncora();
      delay(300); return;
    }
    if (cmd[8]=='1' && !anchorMode) {
      northMode = !northMode; anchorMode = false;
      if (northMode) {
        northHeadingTarget=heading; giroIntegral=0; lastGiroError=0; lastGiroTime=millis();
        #ifdef USE_BUZZER
          digitalWrite(buz,HIGH); delay(300); digitalWrite(buz,LOW);
        #endif
      } else {
        giroIntegral=0; lastGiroError=0; headIntegral=0; lastHeadError=0;
        if (motorLigado) motorWrite(acelerador,0);
        #ifdef USE_BUZZER
          digitalWrite(buz,HIGH); delay(700); digitalWrite(buz,LOW);
        #endif
      }
      delay(300); return;
    }
    if (northMode) {
      if (cmd[3]=='1' && aceleracao<255){ aceleracao+=3; motorLigado=true; motorWrite(acelerador, max(aceleracao, pwmHeliceMin)); }
      if (cmd[4]=='1' && aceleracao>pwmHeliceMin){ aceleracao-=3; if(motorLigado) motorWrite(acelerador, max(aceleracao, pwmHeliceMin)); }
      if (cmd[0]=='1'){
        motorLigado=!motorLigado;
        if (motorLigado) { if (aceleracao < pwmHeliceMin) aceleracao = pwmHeliceMin; motorWrite(acelerador, aceleracao); }
        else { motorWrite(acelerador, pwmMotorOff); }
      }
    }
    if (!anchorMode && !northMode) {
      if (cmd[0]=='1'){
        motorLigado=!motorLigado;
        if (motorLigado) { if (aceleracao < pwmHeliceMin) aceleracao = pwmHeliceMin; motorWrite(acelerador, aceleracao); }
        else { motorWrite(acelerador, pwmMotorOff); }
      }
      if (cmd[3]=='1' && aceleracao<255){ aceleracao+=3; motorLigado=true; motorWrite(acelerador, max(aceleracao, pwmHeliceMin)); }
      if (cmd[4]=='1' && aceleracao>pwmHeliceMin){ aceleracao-=3; motorLigado=true; motorWrite(acelerador, max(aceleracao, pwmHeliceMin)); }
      if (cmd[1]=='1'){ motorWrite(left,230); motorWrite(right,0); tempoLigadoGiro=millis(); }
      else if (cmd[2]=='1'){ motorWrite(right,230); motorWrite(left,0); tempoLigadoGiro=millis(); }
      if (cmd[5]=='1'){ digitalWrite(pinUp,HIGH); digitalWrite(pinDown,LOW); tempoLigadoUpDown=millis(); }
      if (cmd[6]=='1'){ digitalWrite(pinUp,LOW); digitalWrite(pinDown,HIGH); tempoLigadoUpDown=millis(); }
    }
  }

  // Timeouts hold NRF — só agem se BLE nao estiver controlando o mesmo atuador
  if (!anchorMode && !northMode && !upAtivo && !downAtivo && (millis()-tempoLigadoUpDown) > 150) {
    digitalWrite(pinUp,LOW); digitalWrite(pinDown,LOW); tempoLigadoUpDown=millis();
  }
  if (!anchorMode && !northMode && !giroDir && !giroEsq && (millis()-tempoLigadoGiro) > 150) {
    motorWrite(left,0); motorWrite(right,0); tempoLigadoGiro=millis();
  }

  #else
  // ========================================================
  //         MODO SEM NRF — botao fisico
  // ========================================================

  #ifdef LOG_ENABLE
    if (!anchorMode && (millis() - lastStatusPrint) > 2000) {
      lastStatusPrint = millis();
      Serial.print(F("[STATUS] Hdg:")); Serial.print(heading, 1);
      Serial.print(F(" BLE:")); Serial.print(bleConnected ? F("OK") : F("--"));
      Serial.print(F(" GPS:"));
      if (gps.location.isValid() && gps.location.age() < 5000) {
        Serial.print(F("FIX age=")); Serial.print(gps.location.age());
        Serial.print(F("ms sats=")); Serial.print(gps.satellites.value());
        Serial.print(F(" Lat:")); Serial.print(gps.location.lat(), 6);
        Serial.print(F(" Lon:")); Serial.println(gps.location.lng(), 6);
      } else {
        Serial.print(F("SEM FIX chars=")); Serial.println(gps.charsProcessed());
      }
    }
  #endif
  #endif // USE_NRF

  // ========================================================
  //         TIMEOUTS BLE HOLD — seguranca
  // ========================================================
  if ((giroDir || giroEsq) && (millis() - lastGiroCmdTime) > holdTimeout) {
    pararGiro();
  }
  if ((upAtivo || downAtivo) && (millis() - lastUpDownCmdTime) > holdTimeout) {
    pararUpDown();
  }

  // ========================================================
  //         ANCORA — CICLO GPS (500ms)
  // ========================================================
  if (anchorMode && gps.location.isValid()) {
    long now = millis();
    if (now - lastGPSTime >= 500) {
      double dt_pid = constrain((now - lastGPSTime) / 1000.0, 0.05, 2.0);
      lastGPSTime   = now;

      double curLat  = gps.location.lat();
      double curLon  = gps.location.lng();
      double dist    = getDistance(curLat, curLon, anchorLat, anchorLon);
      double bearing = getBearing(curLat, curLon, anchorLat, anchorLon);
      distancia = dist;

      if (lastDist < 0) { lastDist = dist; driftRate = 0.0; }
      else              { driftRate = (dist - lastDist) / dt_pid; lastDist = dist; }

      if (!bearingReady) {
        bearingFiltered = bearing; bearingReady = true;
      } else {
        double diff = bearing - bearingFiltered;
        if (diff >  180.0) diff -= 360.0;
        if (diff < -180.0) diff += 360.0;
        bearingFiltered += 0.6 * diff;
        if (bearingFiltered <   0.0) bearingFiltered += 360.0;
        if (bearingFiltered >= 360.0) bearingFiltered -= 360.0;
      }

      double driftContrib = constrain(driftRate * 0.8, 0.0, 2.0);
      double distError    = dist + driftContrib;

      distIntegral += distError * dt_pid;
      double windupCap = (dist * 25.0 > 80.0) ? dist * 25.0 : 80.0;
      distIntegral = constrain(distIntegral, 0.0, windupCap);
      double distDerivative = (distError - lastDistError) / dt_pid;
      lastDistError = distError;

      bool zonamorta = (dist < anchorStopDistance);
      int  pwmAlvo;

      if (zonamorta) {
        int holdPwm = constrain((int)(Ki_dist * distIntegral), 0, pwmHeliceMin * 3);
        pwmAlvo     = holdPwm;
      } else {
        double pidDist = Kp_dist * distError + Ki_dist * distIntegral + Kd_dist * distDerivative;
        int pwm = constrain((int)pidDist, 0, pwmMax);
        double alpha = (pwm < (int)pwmFiltered) ? 0.4 : 0.75;
        pwmFiltered  = alpha * pwmFiltered + (1.0 - alpha) * (double)pwm;
        pwmAlvo      = constrain((int)pwmFiltered, 0, pwmMax);
        if (pwmAlvo > 0 && pwmAlvo < pwmHeliceMin) pwmAlvo = pwmHeliceMin;
      }

      if (pwmAlvo == 0) pwmRampAtual = 0;
      else if (pwmRampAtual < pwmAlvo) pwmRampAtual = min(pwmRampAtual + pwmRampStep, pwmAlvo);
      else pwmRampAtual = pwmAlvo;

      bool motorAlinhado = zonamorta || (bearingReady && abs(anchorHeadError) <= 13.0);
      pwmComHeading = motorAlinhado ? pwmRampAtual : 0;
      motorWrite(acelerador, pwmComHeading);

      #ifdef LOG_ENABLE
        float elapsed = (millis() - anchorStartTime) / 1000.0f;
        const char *zonaStr  = zonamorta           ? "MORT" : (dist < giroMinDist) ? "APRO" : "CORR";
        const char *driftStr = (driftRate >  0.05) ? ">afa" : (driftRate < -0.05)  ? "<apr" : "~est";
        const char *giroStr  = (distancia < giroMinDist)                 ? "PROX"
                             : (abs(anchorHeadError) <= headingDeadzone) ? "ALIN"
                             : (anchorHeadError > 0)                     ? "GIR.D" : "GIR.E";
        const char *helStr   = (pwmComHeading > 0)        ? "LIGA"
                             : (zonamorta && pwmAlvo > 0) ? "HOLD"
                             : (!motorAlinhado)            ? "AGUA" : "PARA";
        const char *headStr  = (abs(anchorHeadError) <= headingDeadzone) ? "ok"
                             : (abs(anchorHeadError) <= 30.0)            ? "alin" : "DSAL";
        Serial.print(F("\r["));        Serial.print(elapsed, 1);
        Serial.print(F("s] D:"));     Serial.print(dist, 2);
        Serial.print(F("m["));        Serial.print(zonaStr);
        Serial.print(F("] Dr:"));     Serial.print(driftRate, 2);
        Serial.print(driftStr);
        Serial.print(F(" | G:"));     Serial.print(bearingFiltered, 1);
        Serial.print(F("/"));         Serial.print(heading, 1);
        Serial.print(F(" err="));     Serial.print(anchorHeadError, 1);
        Serial.print(F("["));         Serial.print(giroStr);
        Serial.print(F("] | H:"));    Serial.print(pwmComHeading);
        Serial.print(F("("));         Serial.print(pwmRampAtual);
        Serial.print(F("/"));         Serial.print(pwmAlvo);
        Serial.print(F(")["));        Serial.print(helStr);
        Serial.print(F("] I:"));      Serial.print(distIntegral, 1);
        Serial.print(F("["));         Serial.print(headStr);
        Serial.print(F("]      \r"));
      #endif
    }
  }

  // ========================================================
  //         TELEMETRIA BLE (500ms)
  //         $lat,lon,hdg,spd,dist,brg,anc,pwm,nrt,mot,sat\n
  // ========================================================
  if (bleConnected && (millis() - lastTelemetryTime) >= 500) {
    lastTelemetryTime = millis();
    bool gpsOk = gps.location.isValid() && gps.location.age() < 3000;
    String tel = "$";
    tel += String(gpsOk ? gps.location.lat() : 0.0, 7); tel += ",";
    tel += String(gpsOk ? gps.location.lng() : 0.0, 7); tel += ",";
    tel += String(heading, 1);                            tel += ",";
    tel += String(gpsOk ? gps.speed.kmph() : 0.0, 2);   tel += ",";
    tel += String(anchorMode ? distancia : 0.0, 2);      tel += ",";
    tel += String(anchorMode ? bearingFiltered : 0.0, 1);tel += ",";
    tel += String(anchorMode ? 1 : 0);                   tel += ",";
    tel += String(pwmComHeading);                        tel += ",";
    tel += String(northMode ? 1 : 0);                    tel += ",";
    tel += String(motorLigado ? 1 : 0);
    tel += ",";
    tel += String(gps.satellites.value());
    tel += "\n";
    bleSend(tel);
  }

  // ========================================================
  //         ANCORA — CICLO GIRO (100ms)
  // ========================================================
  if (anchorMode && bearingReady && (millis() - updateGiro) > 100) {
    if (distancia >= giroMinDist) {
      anchorHeadError = bearingFiltered - (double)heading;
      if (anchorHeadError >  180.0) anchorHeadError -= 360.0;
      if (anchorHeadError < -180.0) anchorHeadError += 360.0;

      if (abs(anchorHeadError) <= headingDeadzone) {
        motorWrite(left, 0); motorWrite(right, 0);
        giroIntegral = 0;
      } else {
        int pwmGiro = calcPidGiro(anchorHeadError);
        if (anchorHeadError > 0) { motorWrite(right, pwmGiro); motorWrite(left,  0); }
        else                     { motorWrite(left,  pwmGiro); motorWrite(right, 0); }
      }
    }
    updateGiro = millis();
  }

  // ========================================================
  //         MODO NORTE
  // ========================================================
  if (northMode) {
    double error = northHeadingTarget - (double)heading;
    if (error >  180.0) error -= 360.0;
    if (error < -180.0) error += 360.0;
    const double dt = 0.02;
    headIntegral += error * dt;
    headIntegral  = constrain(headIntegral, -1000.0, 1000.0);
    double deriv  = (error - lastHeadError) / dt;
    lastHeadError = error;
    double pidOut = Kp_head * error + Ki_head * headIntegral + Kd_head * deriv;
    if (abs(error) <= headingDeadzone) {
      motorWrite(left, 0); motorWrite(right, 0); giroIntegral = 0;
    } else {
      int pwmGiro = calcPidGiro(error);
      if (pidOut > 0) { motorWrite(right, pwmGiro); motorWrite(left,  0); }
      else            { motorWrite(left,  pwmGiro); motorWrite(right, 0); }
    }
  }

  // ========================================================
  //         APONTA NORTE — modo calibração bússola
  //         PWM fixo 120, histerese 5°, ativado via BLE $APN
  // ========================================================
  if (apontaNorteMode && !anchorMode && !northMode) {
    double erroNorte = 0.0 - (double)heading;
    if (erroNorte >  180.0) erroNorte -= 360.0;
    if (erroNorte < -180.0) erroNorte += 360.0;
    const int    pwmCalib   = 120;
    const double histerese  = 5.0;
    if (abs(erroNorte) <= histerese) {
      motorWrite(left, 0); motorWrite(right, 0);
    } else {
      if (erroNorte > 0) { motorWrite(right, pwmCalib); motorWrite(left,  0); }
      else               { motorWrite(left,  pwmCalib); motorWrite(right, 0); }
    }
  }

  delay(20);
}
