// ================================================================
//  remote_task (nucleo 0): le o nRF24 a cada 10 ms e envia cada
//  pacote recebido para a fila de comandos (CmdType::NrfPacket).
//  Se o radio falhar, tenta reinicializar a cada 5 s.
// ================================================================
#pragma once

void remote_start();
