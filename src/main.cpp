// ================= DEFINES =================
//#define USE_NRF     // Comente = bancada (botao pino 4); Descomente = radio NRF24L01
#define LOG_ENABLE    // Habilita debug via Serial 115200
//#define TYPE_BRAGA

// ================= LIBS =================
#include <Wire.h>
#include <EEPROM.h>
#include <SoftwareSerial.h>
#include <TinyGPS++.h>
#include <HMC5883L.h>
#include <Arduino.h>
#ifdef USE_NRF
  #include <SPI.h>
  #include <nRF24L01.h>
  #include <RF24.h>
#endif

// ================= HARDWARE FIXO =================
SoftwareSerial Serial2(7, 8);   // GPS: RX=7 TX=8
const int left       = 5;       // PWM giro esquerda
const int right      = 6;       // PWM giro direita
const int acelerador = 3;       // PWM helice
const int buz        = 2;       // buzzer
#ifdef TYPE_BRAGA
  const int up   = 0;
  const int down = 1;
#endif

// ================= HARDWARE CONDICIONAL =================
#ifdef USE_NRF
  RF24 radio(9, 10);
  const byte address[6] = "00001";
  #define MAX_CONTROLES 5
  uint32_t controlesMem[MAX_CONTROLES];
  unsigned long bootTime;
  bool modoCadastro = true;
  const unsigned long cadastroTimeout = 1500;
  long tempoLigadoGiro   = 0;
  long tempoLigadoUpDown = 0;
#else
  const int PIN_BTN_ANCORA       = 4;    // INPUT_PULLUP: pressionar = GND
  unsigned long lastBtnPress     = 0;
  const unsigned long debounceMs = 400;
#endif

// ================= OBJETOS =================
TinyGPSPlus gps;
HMC5883L    compass;

// ================= ESTADOS =================
bool anchorMode  = false;
bool northMode   = false;
bool motorLigado = false;

// ================= ANCORA =================
double anchorLat = 0;
double anchorLon = 0;
// anchorStopDistance  = zona morta (helice para, integral preservado)
// anchorStartDistance = helice liga acima disto
// giroMinDist         = igual ao start: elimina zona onde helice liga sem giro
const double anchorStopDistance  = 1.0;
const double anchorStartDistance = 1.5;
const double giroMinDist         = 1.5;
double distancia       = 0;
int    pwmComHeading   = 0;
bool   apontaNorteMode = false;
double bearingFiltered = 0;
bool   bearingReady    = false;
double lastDist        = -1;   // -1 = sentinela: primeira leitura GPS
double driftRate       = 0.0;  // m/s: positivo=afastando, negativo=aproximando
double anchorHeadError = 0.0;  // atualizado pelo ciclo de giro (100ms)
const int pwmHeliceMin = 15;
const int pwmRampStep  = 20;
int       pwmRampAtual = 0;
unsigned long anchorStartTime = 0;  // para tempo decorrido no debug

// ================= HEADING =================
float heading           = 0;
long  lastCompassReaded = 0;
long  updateGiro        = 0;
long  buzzerLast        = 10;
bool  buzzerAtivo       = false;
const double headingDeadzone = 8.0;
float northHeadingTarget     = 0;

// ================= PID DISTANCIA =================
double Kp_dist = 1.0, Ki_dist = 0.5, Kd_dist = 0.8;
double distIntegral = 0, lastDistError = 0;
const int pwmMin = 10;
const int pwmMax = 170;
double pwmFiltered = 0;

// ================= PID HEADING (modo norte) =================
double Kp_head = 4.0, Ki_head = 0.02, Kd_head = 1.5;
double headIntegral = 0, lastHeadError = 0;

// ================= PID GIRO =================
double Kp_giro = 3.0, Ki_giro = 0.1, Kd_giro = 0.0;
double giroIntegral = 0, lastGiroError = 0;
const int    pwmGiroMin  = 110;
const int    pwmGiroMax  = 255;
const double zonaForte   = 40.0;
const int    pwmFinoMax  = 130;
const int    pwmForteMin = 180;
unsigned long lastGiroTime = 0;

// ================= CONTROLE =================
int           aceleracao  = 0;
unsigned long lastGPSTime = 0;

// ================= DEBUG TIMERS =================
#ifdef LOG_ENABLE
  unsigned long lastStatusPrint = 0;
  unsigned long lastGiroPrint   = 0;
#endif

// ================= EEPROM BUSSOLA =================
#define EEPROM_COMPASS_FLAG 100
#define EEPROM_COMPASS_XOFF 104
#define EEPROM_COMPASS_YOFF 108
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

// ================= EEPROM CONTROLES (apenas USE_NRF) =================
#ifdef USE_NRF
void carregarControlesEEPROM() {
  for (int i = 0; i < MAX_CONTROLES; i++) EEPROM.get(i * 4, controlesMem[i]);
}
bool controleAutorizado(uint32_t id) {
  for (int i = 0; i < MAX_CONTROLES; i++)
    if (controlesMem[i] == id && id != 0) return true;
  return false;
}
void salvarControle(uint8_t slot, uint32_t id) {
  controlesMem[slot] = id;
  EEPROM.put(slot * 4, id);
  for (int i = 0; i <= slot; i++) {
    digitalWrite(buz, HIGH); delay(300); digitalWrite(buz, LOW); delay(200);
  }
}
#endif

// ================= BUSSOLA =================
void carregarCalibracaoBussola() {
  byte flag;
  EEPROM.get(EEPROM_COMPASS_FLAG, flag);
  if (flag == 0xAA) {
    EEPROM.get(EEPROM_COMPASS_XOFF, compassXOffset);
    EEPROM.get(EEPROM_COMPASS_YOFF, compassYOffset);
    #ifdef LOG_ENABLE
      Serial.print(F("  Bussola: calibracao EEPROM OK (Xoff="));
      Serial.print(compassXOffset, 2);
      Serial.print(F(" Yoff=")); Serial.print(compassYOffset, 2);
      Serial.println(F(")"));
    #endif
  } else {
    #ifdef LOG_ENABLE
      Serial.println(F("  Bussola: SEM calibracao salva!"));
    #endif
  }
}

void calibrarBussola() {
  float minX = 9999, maxX = -9999, minY = 9999, maxY = -9999;
  digitalWrite(buz, HIGH);
  long t0 = millis();
  analogWrite(left, 200); analogWrite(right, 0);
  while (millis() - t0 < 8000) {
    Vector m = compass.readNormalize();
    minX = min(minX, m.XAxis); maxX = max(maxX, m.XAxis);
    minY = min(minY, m.YAxis); maxY = max(maxY, m.YAxis);
    delay(50);
  }
  analogWrite(left, 0); analogWrite(right, 0);
  digitalWrite(buz, LOW); delay(1000);
  digitalWrite(buz, HIGH);
  analogWrite(left, 0); analogWrite(right, 200);
  t0 = millis();
  while (millis() - t0 < 8000) {
    Vector m = compass.readNormalize();
    minX = min(minX, m.XAxis); maxX = max(maxX, m.XAxis);
    minY = min(minY, m.YAxis); maxY = max(maxY, m.YAxis);
    delay(50);
  }
  analogWrite(left, 0); analogWrite(right, 0);
  digitalWrite(buz, LOW); delay(1000);
  for (int i = 0; i < 3; i++) {
    digitalWrite(buz, HIGH); delay(200); digitalWrite(buz, LOW); delay(200);
  }
  compassXOffset = (maxX + minX) / 2.0f;
  compassYOffset = (maxY + minY) / 2.0f;
  EEPROM.put(EEPROM_COMPASS_XOFF, compassXOffset);
  EEPROM.put(EEPROM_COMPASS_YOFF, compassYOffset);
  byte flag = 0xAA;
  EEPROM.put(EEPROM_COMPASS_FLAG, flag);
}

float readCompassCalibrado() {
  Vector norm = compass.readNormalize();
  float x = norm.XAxis - compassXOffset;
  float y = norm.YAxis - compassYOffset;
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
void beep(int) {
  digitalWrite(buz, HIGH);
  buzzerLast = millis();
  buzzerAtivo = true;
}

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
      Serial.println();
      Serial.println(F("============================================"));
      Serial.println(F("            ANCORA ATIVADA"));
      Serial.print(F("  Ponto: Lat ")); Serial.println(lat, 7);
      Serial.print(F("         Lon ")); Serial.println(lon, 7);
      Serial.print(F("  GPS age   : ")); Serial.print(gps.location.age()); Serial.println(F(" ms"));
      Serial.print(F("  Satelites : ")); Serial.println(gps.satellites.value());
      Serial.println(F("============================================"));
      Serial.println();
    #endif
    digitalWrite(buz, HIGH); delay(300);
    digitalWrite(buz, LOW);  delay(100);
    digitalWrite(buz, HIGH); delay(300);
    digitalWrite(buz, LOW);
  } else {
    #ifdef LOG_ENABLE
      Serial.println();
      Serial.println(F("[ERRO] GPS invalido - ancora NAO ativada"));
      Serial.print(F("  isValid  : ")); Serial.println(gps.location.isValid() ? F("sim") : F("nao"));
      Serial.print(F("  age      : ")); Serial.print(gps.location.age()); Serial.println(F(" ms (max 2000)"));
      Serial.print(F("  lat      : ")); Serial.println(lat, 7);
      Serial.print(F("  lon      : ")); Serial.println(lon, 7);
      Serial.println();
    #endif
    for (int i = 0; i < 3; i++) {
      digitalWrite(buz, HIGH); delay(80); digitalWrite(buz, LOW); delay(80);
    }
  }
}

// ================= DESATIVAR ANCORA =================
void desativarAncora() {
  #ifdef LOG_ENABLE
    float elapsed = (millis() - anchorStartTime) / 1000.0f;
    Serial.println();
    Serial.println(F("============================================"));
    Serial.println(F("            ANCORA DESATIVADA"));
    Serial.print(F("  Tempo ativo: ")); Serial.print(elapsed, 1); Serial.println(F(" s"));
    Serial.println(F("============================================"));
    Serial.println();
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
  analogWrite(acelerador, 0);
  analogWrite(left,  0);
  analogWrite(right, 0);
  digitalWrite(buz, HIGH); delay(700); digitalWrite(buz, LOW);
}

// ================= SETUP =================
void setup() {
  #ifdef LOG_ENABLE
    Serial.begin(115200);
    delay(100);
    Serial.println();
    Serial.println(F("========================================"));
    Serial.println(F("      MODULO BARCO  -  firmware v1.0"));
    #ifdef USE_NRF
      Serial.println(F("      Modo compilado : RADIO NRF24L01"));
    #else
      Serial.println(F("      Modo compilado : BANCADA (botao)"));
    #endif
    Serial.println(F("      Debug           : ATIVO | 115200 baud"));
    Serial.println(F("========================================"));
    Serial.println(F("Iniciando..."));
  #endif

  Serial2.begin(9600);
  Wire.begin();
  pinMode(left,       OUTPUT);
  pinMode(right,      OUTPUT);
  pinMode(acelerador, OUTPUT);
  pinMode(buz,        OUTPUT);
  #ifdef TYPE_BRAGA
    pinMode(up,   OUTPUT);
    pinMode(down, OUTPUT);
  #endif

  #ifdef USE_NRF
    radio.begin();
    radio.openReadingPipe(0, address);
    radio.setDataRate(RF24_250KBPS);
    radio.startListening();
    carregarControlesEEPROM();
    bootTime = millis();
    #ifdef LOG_ENABLE
      Serial.println(F("  NRF24L01      : OK"));
    #endif
  #else
    pinMode(PIN_BTN_ANCORA, INPUT_PULLUP);
    #ifdef LOG_ENABLE
      Serial.print(F("  Botao ancora  : pino "));
      Serial.print(PIN_BTN_ANCORA);
      Serial.println(F(" [INPUT_PULLUP - pressionar = ativar/desativar]"));
    #endif
  #endif

  compass.setRange(HMC5883L_RANGE_1_3GA);
  compass.setMeasurementMode(HMC5883L_CONTINOUS);
  compass.setDataRate(HMC5883L_DATARATE_30HZ);
  compass.setSamples(HMC5883L_SAMPLES_8);
  compass.setOffset(0, 0, 0);
  carregarCalibracaoBussola();

  #ifdef LOG_ENABLE
    Serial.println(F("  GPS           : aguardando fix..."));
    Serial.println(F("  HMC5883L      : OK"));
    Serial.println(F("Pronto.\n"));
  #endif

  for (int i = 0; i < 2; i++) {
    digitalWrite(buz, HIGH); delay(200); digitalWrite(buz, LOW); delay(200);
  }
}

// ================= LOOP =================
void loop() {

  // --- Bussola Kalman (50ms) ---
  if ((millis() - lastCompassReaded) > 50) {
    heading = kfHeading.update(readCompassCalibrado());
    lastCompassReaded = millis();
  }

  // --- Buzzer one-shot ---
  if (buzzerAtivo && (millis() - buzzerLast) > 10) {
    digitalWrite(buz, LOW);
    buzzerAtivo = false;
  }

  // --- GPS ---
  while (Serial2.available()) gps.encode(Serial2.read());

  // ========================================================
  //              ENTRADA DE COMANDOS
  // ========================================================
  #ifdef USE_NRF
  // ---- Cadastro timeout ----
  if (millis() - bootTime > cadastroTimeout) modoCadastro = false;

  if (radio.available()) {
    char text[18] = {0};
    radio.read(&text, sizeof(text));
    char idStr[6];
    memcpy(idStr, &text[12], 5); idStr[5] = '\0';
    uint32_t controlID = (uint32_t)atoi(idStr);

    // --- Modo cadastro ---
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

    // --- Validacao ---
    if (!controleAutorizado(controlID)) {
      for (int i=0;i<6;i++){ digitalWrite(buz,HIGH); delay(30); digitalWrite(buz,LOW); delay(30); }
      return;
    }

    char *cmd = &text[0];
    beep(0);

    // Ancora
    if (cmd[7]=='1' && !northMode) {
      if (!anchorMode) ativarAncora(); else desativarAncora();
      delay(300); return;
    }
    // Norte
    if (cmd[8]=='1' && !anchorMode) {
      northMode = !northMode; anchorMode = false;
      if (northMode) {
        northHeadingTarget=heading; giroIntegral=0; lastGiroError=0; lastGiroTime=millis();
        digitalWrite(buz,HIGH); delay(300); digitalWrite(buz,LOW);
      } else {
        giroIntegral=0; lastGiroError=0; headIntegral=0; lastHeadError=0;
        digitalWrite(buz,HIGH); delay(700); digitalWrite(buz,LOW);
        if (motorLigado) analogWrite(acelerador,0);
      }
      delay(300); return;
    }
    // Controles modo norte
    if (northMode) {
      if (cmd[3]=='1' && aceleracao<255){ aceleracao+=3; motorLigado=true; analogWrite(acelerador,aceleracao); }
      if (cmd[4]=='1' && aceleracao>0)  { aceleracao-=3; if(motorLigado) analogWrite(acelerador,aceleracao); }
      if (cmd[0]=='1'){ motorLigado=!motorLigado; analogWrite(acelerador,motorLigado?aceleracao:0); }
    }
    // Controles modo manual
    if (!anchorMode && !northMode) {
      if (cmd[0]=='1'){ motorLigado=!motorLigado; analogWrite(acelerador,motorLigado?aceleracao:0); }
      if (cmd[3]=='1' && aceleracao<255){ aceleracao+=3; motorLigado=true; analogWrite(acelerador,aceleracao); }
      if (cmd[4]=='1' && aceleracao>0)  { aceleracao-=3; motorLigado=true; analogWrite(acelerador,aceleracao); }
      if      (cmd[1]=='1'){ analogWrite(left,230); analogWrite(right,0);  tempoLigadoGiro=millis(); }
      else if (cmd[2]=='1'){ analogWrite(right,230); analogWrite(left,0);  tempoLigadoGiro=millis(); }
      #ifdef TYPE_BRAGA
        if (cmd[5]=='1'){ digitalWrite(up,HIGH); digitalWrite(down,LOW);  tempoLigadoUpDown=millis(); }
        if (cmd[6]=='1'){ digitalWrite(up,LOW);  digitalWrite(down,HIGH); tempoLigadoUpDown=millis(); }
      #endif
    }
  } // radio.available

  // Timeouts manuais
  #ifdef TYPE_BRAGA
    if (!anchorMode && !northMode && (millis()-tempoLigadoUpDown)>150){
      digitalWrite(up,LOW); digitalWrite(down,LOW); tempoLigadoUpDown=millis();
    }
  #endif
  if (!anchorMode && !northMode && (millis()-tempoLigadoGiro)>150){
    analogWrite(left,0); analogWrite(right,0); tempoLigadoGiro=millis();
  }

  #else
  // ========================================================
  //         MODO BANCADA — botao na pino 4
  // ========================================================
  if (digitalRead(PIN_BTN_ANCORA) == LOW && (millis() - lastBtnPress) > debounceMs) {
    lastBtnPress = millis();
    if (!anchorMode) ativarAncora(); else desativarAncora();
    delay(300);
  }

  // Status periodico quando ancora desligada (a cada 2s)
  #ifdef LOG_ENABLE
    if (!anchorMode && (millis() - lastStatusPrint) > 2000) {
      lastStatusPrint = millis();
      Serial.print(F("[STATUS] Heading: ")); Serial.print(heading, 1); Serial.print(F(" deg  |  GPS: "));
      if (gps.location.isValid() && gps.location.age() < 5000) {
        Serial.print(F("FIX OK  age=")); Serial.print(gps.location.age());
        Serial.print(F("ms  sats=")); Serial.print(gps.satellites.value());
        Serial.print(F("  Lat:")); Serial.print(gps.location.lat(), 7);
        Serial.print(F("  Lon:")); Serial.println(gps.location.lng(), 7);
      } else {
        Serial.print(F("SEM FIX  chars=")); Serial.println(gps.charsProcessed());
      }
    }
  #endif

  #endif // USE_NRF

  // ========================================================
  //         ANCORA — CICLO GPS (500 ms)
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

      // Velocidade de deriva
      if (lastDist < 0) { lastDist = dist; driftRate = 0.0; }
      else { driftRate = (dist - lastDist) / dt_pid; lastDist = dist; }

      // Filtro exponencial no bearing
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

      // Erro preditivo: antecipa onde barco estara em ~0.8s se afastando
      double driftContrib = constrain(driftRate * 0.8, 0.0, 2.0);
      double distError    = dist + driftContrib;

      // PID distancia com anti-windup que preserva memoria ambiental
      distIntegral += distError * dt_pid;
      double windupCap = (dist * 25.0 > 80.0) ? dist * 25.0 : 80.0;
      distIntegral = constrain(distIntegral, 0.0, windupCap);
      double distDerivative = (distError - lastDistError) / dt_pid;
      lastDistError = distError;

      bool zonamorta = (dist < anchorStopDistance);
      int pwmAlvo;

      if (zonamorta) {
        // Zona morta: so o integral sustenta o barco (memoria do vento/corrente)
        // distIntegral NAO e zerado — preserva o aprendizado ambiental
        int holdPwm = constrain((int)(Ki_dist * distIntegral), 0, pwmHeliceMin * 3);
        pwmAlvo     = holdPwm;
        pwmFiltered = (double)holdPwm;
      } else {
        // PID completo fora da zona morta
        double pidDist = Kp_dist * distError + Ki_dist * distIntegral + Kd_dist * distDerivative;
        int pwm = constrain((int)pidDist, 0, pwmMax);
        double alpha = (pwm < (int)pwmFiltered) ? 0.4 : 0.75;
        pwmFiltered  = alpha * pwmFiltered + (1.0 - alpha) * (double)pwm;
        pwmAlvo      = constrain((int)pwmFiltered, 0, pwmMax);
        if (pwmAlvo > 0 && pwmAlvo < pwmHeliceMin) pwmAlvo = pwmHeliceMin;
      }

      // Rampa de segurança
      if (pwmAlvo == 0) pwmRampAtual = 0;
      else if (pwmRampAtual < pwmAlvo) pwmRampAtual = min(pwmRampAtual + pwmRampStep, pwmAlvo);
      else pwmRampAtual = pwmAlvo;

      // Direcao primeiro: bloqueia empuxo se motor desalinhado (exceto zona morta)
      bool motorAlinhado = zonamorta || (bearingReady && abs(anchorHeadError) <= 30.0);
      pwmComHeading = motorAlinhado ? pwmRampAtual : 0;
      analogWrite(acelerador, pwmComHeading);

      // ---- DEBUG CICLO GPS ----
      #ifdef LOG_ENABLE
        float elapsed = (millis() - anchorStartTime) / 1000.0f;

        const char *zonaStr   = zonamorta                  ? "ZONA MORTA (<1m)"
                              : (dist < giroMinDist)       ? "APROXIMANDO (1-1.5m)"
                                                           : "CORRECAO ATIVA (>1.5m)";

        const char *driftStr  = (driftRate >  0.05)        ? "afastando  >"
                              : (driftRate < -0.05)        ? "< aproximando"
                                                           : "~ estavel";

        const char *headStr   = (abs(anchorHeadError) <= headingDeadzone) ? "ALINHADO"
                              : (abs(anchorHeadError) <= 30.0)            ? "alinhando..."
                                                                          : "DESALINHADO";

        const char *heliceStr = (pwmComHeading > 0)                       ? "LIGADA"
                              : (zonamorta && pwmAlvo > 0)                ? "HOLDING (zona morta)"
                              : (!motorAlinhado)                           ? "AGUARD. ALINHAMENTO"
                                                                          : "PARADA";

        Serial.println(F("--------------------------------------------------"));
        Serial.print(F(" ANCORA  t=")); Serial.print(elapsed, 1); Serial.println(F("s"));
        Serial.println(F("--------------------------------------------------"));
        Serial.print(F("  Posicao atual : Lat ")); Serial.print(curLat, 7);
        Serial.print(F("   Lon ")); Serial.println(curLon, 7);
        Serial.print(F("  Ponto ancora  : Lat ")); Serial.print(anchorLat, 7);
        Serial.print(F("   Lon ")); Serial.println(anchorLon, 7);
        Serial.println();
        Serial.print(F("  Distancia     : ")); Serial.print(dist, 2); Serial.print(F(" m   [")); Serial.print(zonaStr); Serial.println(F("]"));
        Serial.print(F("  Deriva        : ")); Serial.print(driftRate, 2); Serial.print(F(" m/s  ")); Serial.println(driftStr);
        Serial.println();
        Serial.print(F("  Bearing alvo  : ")); Serial.print(bearingFiltered, 1); Serial.println(F(" deg  (direcao p/ ponto ancora)"));
        Serial.print(F("  Motor aponta  : ")); Serial.print(heading, 1); Serial.println(F(" deg  (bussola Kalman)"));
        Serial.print(F("  Erro direcao  : ")); Serial.print(anchorHeadError, 1); Serial.print(F(" deg   [")); Serial.print(headStr); Serial.println(F("]"));
        Serial.println();
        Serial.print(F("  PWM alvo      : ")); Serial.println(pwmAlvo);
        Serial.print(F("  PWM rampa     : ")); Serial.println(pwmRampAtual);
        Serial.print(F("  Helice        : [")); Serial.print(heliceStr); Serial.println(F("]"));
        Serial.print(F("  Integral dist : ")); Serial.print(distIntegral, 1); Serial.println(F("  (memoria ambiental)"));
        Serial.println();
      #endif
    }
  }

  // ========================================================
  //         ANCORA — CICLO GIRO (100 ms)
  // ========================================================
  if (anchorMode && bearingReady && (millis() - updateGiro) > 100) {
    if (distancia >= giroMinDist) {
      anchorHeadError = bearingFiltered - (double)heading;
      if (anchorHeadError >  180.0) anchorHeadError -= 360.0;
      if (anchorHeadError < -180.0) anchorHeadError += 360.0;

      if (abs(anchorHeadError) <= headingDeadzone) {
        analogWrite(left, 0); analogWrite(right, 0);
        giroIntegral = 0;
        #ifdef LOG_ENABLE
          if (millis() - lastGiroPrint > 500) {
            lastGiroPrint = millis();
            Serial.print(F("[GIRO] Alinhado  erro=")); Serial.print(anchorHeadError, 1);
            Serial.println(F(" deg  - motor parado"));
          }
        #endif
      } else {
        int pwmGiro = calcPidGiro(anchorHeadError);
        if (anchorHeadError > 0) {
          analogWrite(right, pwmGiro); analogWrite(left, 0);
          #ifdef LOG_ENABLE
            if (millis() - lastGiroPrint > 200) {
              lastGiroPrint = millis();
              Serial.print(F("[GIRO] Erro: +")); Serial.print(anchorHeadError, 1);
              Serial.print(F(" deg  -> GIRANDO DIREITA   PWM: ")); Serial.println(pwmGiro);
            }
          #endif
        } else {
          analogWrite(left, pwmGiro); analogWrite(right, 0);
          #ifdef LOG_ENABLE
            if (millis() - lastGiroPrint > 200) {
              lastGiroPrint = millis();
              Serial.print(F("[GIRO] Erro: ")); Serial.print(anchorHeadError, 1);
              Serial.print(F(" deg  -> GIRANDO ESQUERDA  PWM: ")); Serial.println(pwmGiro);
            }
          #endif
        }
      }
    }
    // Perto do ponto (dist < giroMinDist): motor permanece na ultima posicao
    // conhecida apontando ao ponto ancora — nao sobrescreve o giro
    updateGiro = millis();
  }

  // ========================================================
  //         MODO NORTE — ciclo continuo
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
      digitalWrite(left, LOW); digitalWrite(right, LOW); giroIntegral = 0;
    } else {
      int pwmGiro = calcPidGiro(error);
      if (pidOut > 0) { analogWrite(right, pwmGiro); analogWrite(left,  0); }
      else            { analogWrite(left,  pwmGiro); analogWrite(right, 0); }
    }
  }

  delay(20);

  // ========================================================
  //         APONTA NORTE (ativado via cadastro)
  // ========================================================
  if (apontaNorteMode && !anchorMode && !northMode) {
    double erroNorte = 0.0 - (double)heading;
    if (erroNorte >  180.0) erroNorte -= 360.0;
    if (erroNorte < -180.0) erroNorte += 360.0;
    if (abs(erroNorte) <= headingDeadzone) {
      analogWrite(left, 0); analogWrite(right, 0); giroIntegral = 0;
    } else {
      int pwmGiro = calcPidGiro(erroNorte);
      if (erroNorte > 0) { analogWrite(right, pwmGiro); analogWrite(left,  0); }
      else               { analogWrite(left,  pwmGiro); analogWrite(right, 0); }
    }
  }
}
