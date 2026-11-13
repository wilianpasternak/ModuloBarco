// ================================================================
//  PescaPlus — configuracao de hardware, constantes e tasks
// ================================================================
#pragma once
#include "driver/gpio.h"

// ================= DISPOSITIVO =================
#define DEVICE_NAME  "PescaPlus"
#define NVS_NAMESPACE "barco"

// ================= BLE UUIDs =================
#define BLE_SVC_UUID "0000ffe0-0000-1000-8000-00805f9b34fb"
#define BLE_CHR_UUID "0000ffe1-0000-1000-8000-00805f9b34fb"
#define BLE_OTA_UUID "0000ffe2-0000-1000-8000-00805f9b34fb"

// ================= PINOS — ESP32 DevKit Classic =================
#define PIN_GIRO_LEFT   GPIO_NUM_2    // PWM giro esquerda  (LEDC)
#define PIN_GIRO_RIGHT  GPIO_NUM_4    // PWM giro direita   (LEDC)
#define PIN_ACELERADOR  GPIO_NUM_33   // PWM helice         (LEDC)
#define PIN_UP          GPIO_NUM_32   // Subir  (rele: LOW=ativo, HIGH=desligado)
#define PIN_DOWN        GPIO_NUM_13   // Descer (rele: LOW=ativo, HIGH=desligado)
#define PIN_BUZZER      GPIO_NUM_27
#define PIN_GPS_RX      GPIO_NUM_16
#define PIN_GPS_TX      GPIO_NUM_17
#define PIN_I2C_SDA     GPIO_NUM_21
#define PIN_I2C_SCL     GPIO_NUM_22
#define PIN_NRF_CE      GPIO_NUM_14
#define PIN_NRF_CSN     GPIO_NUM_5    // VSPI CS
#define PIN_NRF_SCK     GPIO_NUM_18   // VSPI SCK
#define PIN_NRF_MISO    GPIO_NUM_19   // VSPI MISO
#define PIN_NRF_MOSI    GPIO_NUM_23   // VSPI MOSI
// IRQ do NRF24 nao conectado — leitura por polling
#define PIN_BAT_ADC     GPIO_NUM_34   // ADC1_CH6 (input-only)

// ================= PWM (LEDC) =================
#define PWM_FREQ_HZ     5000
#define PWM_BITS        8

// ================= MOTOR DE GIRO (controle em cascata, steer.cpp) =================
#define GIRO_PWM_START  90    // PWM minimo que tira o giro do lugar (sem empuxo da helice)
#define GIRO_PWM_MAX    255

// ================= BATERIA =================
// Divisor R1=47k R2=10k -> V_bat = V_adc * (47+10)/10
#define BAT_DIVISOR        5.7f
#define BAT_CAL            1.074f   // calibrado: bateria 15V -> divisor 2.614V -> ADC lia 14.1V
#define BAT_READ_INTERVAL  3000     // ms

// ================= NRF24 =================
#define MAX_CONTROLES      5
#define NRF_PAYLOAD_SIZE   18       // tamanho fixo do pacote do controle
#define NRF_CHANNEL        76       // padrao da biblioteca RF24 (igual ao transmissor)

// ================= TASKS: nucleo / prioridade / stack =================
// Nucleo 0: comunicacao (NimBLE, NRF, OTA, telemetria, buzzer, NVS)
// Nucleo 1: controle e sensores, isolados do Bluetooth
#define CORE_COMM  0
#define CORE_CTRL  1

#define PRIO_CONTROL    10
#define PRIO_COMPASS     9
#define PRIO_GPS         8
#define PRIO_REMOTE      7
#define PRIO_OTA         5
#define PRIO_TELEMETRY   3
#define PRIO_BUZZER      2
#define PRIO_SETTINGS    1

#define STACK_CONTROL   6144
#define STACK_COMPASS   3072
#define STACK_GPS       4096
#define STACK_REMOTE    3072
#define STACK_OTA       6144
#define STACK_TELEMETRY 4096
#define STACK_BUZZER    2048
#define STACK_SETTINGS  3072

#define CONTROL_PERIOD_MS  20   // 50 Hz
#define COMPASS_PERIOD_MS  20   // 50 Hz
#define REMOTE_PERIOD_MS   10   // 100 Hz
