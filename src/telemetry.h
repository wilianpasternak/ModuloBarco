// ================================================================
//  telemetry_task (nucleo 0)
//    - Telemetria BLE a cada 500 ms:
//      $lat,lon,hdg,spd,dist,brg,anc,pwm,nrt,mot,sat\n
//    - Bateria (ADC GPIO34) a cada 3 s: $BAT:<volts>:<pct>\n quando muda
// ================================================================
#pragma once

void telemetry_init();     // ADC + leitura inicial da bateria
void telemetry_start();

void battery_get(float* volts, int* percent);
void battery_send();       // envia $BAT atual pelo BLE
