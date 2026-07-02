import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../models/telemetry.dart';

const _serviceUuid        = '0000ffe0-0000-1000-8000-00805f9b34fb';
const _characteristicUuid = '0000ffe1-0000-1000-8000-00805f9b34fb';

class BleService {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _characteristic;
  String _lineBuffer = '';

  final _telemetryController  = StreamController<Telemetry>.broadcast();
  final _connectionController = StreamController<bool>.broadcast();
  final _pwmHelMinController  = StreamController<int>.broadcast();

  Stream<Telemetry> get telemetryStream  => _telemetryController.stream;
  Stream<bool>      get connectionStream => _connectionController.stream;
  Stream<int>       get pwmHelMinStream  => _pwmHelMinController.stream;

  bool get isConnected => _device != null && (_device!.isConnected);

  // UUID: extrai os 4 chars do campo 16-bit (posicao 4-8 sem tracos)
  // Funciona com forma curta "ffe0" e longa "0000ffe0-0000-1000-8000-00805f9b34fb"
  static bool _uuidMatch(String a, String b) {
    a = a.toLowerCase().replaceAll('-', '');
    b = b.toLowerCase().replaceAll('-', '');
    if (a == b) return true;
    String s(String u) => u.length >= 8 ? u.substring(4, 8) : u;
    return s(a) == s(b);
  }

  Future<void> connect(BluetoothDevice device) async {
    await device.connect(timeout: const Duration(seconds: 10));
    // Delay necessario: Android BLE precisa estabilizar antes de discoverServices()
    // Sem isso, discoverServices() pode retornar lista vazia em Samsung/Xiaomi/etc.
    await Future.delayed(const Duration(milliseconds: 300));
    _device = device;
    _connectionController.add(true);

    if (Platform.isAndroid) await device.requestMtu(512);

    final services = await device.discoverServices();
    for (final s in services) {
      if (_uuidMatch(s.uuid.toString(), _serviceUuid)) {
        for (final c in s.characteristics) {
          if (_uuidMatch(c.uuid.toString(), _characteristicUuid)) {
            _characteristic = c;
            await c.setNotifyValue(true);
            c.lastValueStream.listen((value) {
              if (value.isNotEmpty) _onData(value);
            });
            break;
          }
        }
      }
    }

    device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _characteristic = null;
        _connectionController.add(false);
      }
    });
  }

  void _onData(List<int> bytes) {
    _lineBuffer += utf8.decode(bytes, allowMalformed: true);
    while (true) {
      final idx = _lineBuffer.indexOf('\n');
      if (idx < 0) break;
      final line = _lineBuffer.substring(0, idx).trim();
      _lineBuffer = _lineBuffer.substring(idx + 1);
      if (line.startsWith('\$HMN:')) {
        // Resposta de configuracao do pwmHeliceMin
        final val = int.tryParse(line.substring(5));
        if (val != null) _pwmHelMinController.add(val);
      } else if (line.startsWith('\$')) {
        final t = Telemetry.fromLine(line);
        if (t != null) _telemetryController.add(t);
      }
    }
  }

  Future<void> sendCommand(String cmd) async {
    if (_characteristic == null) return;
    final bytes = utf8.encode(cmd.endsWith('\n') ? cmd : '$cmd\n');
    await _characteristic!.write(bytes, withoutResponse: false);
  }

  // --- Ancora / Norte / Motor ---
  Future<void> sendToggleAnchor()  => sendCommand('\$ANC');
  Future<void> sendToggleNorth()   => sendCommand('\$NRT');
  Future<void> sendToggleMotor()   => sendCommand('\$MOT');

  // --- Giro (press/release) ---
  Future<void> sendGiroDirStart()  => sendCommand('\$GTR+');
  Future<void> sendGiroDirStop()   => sendCommand('\$GTR-');
  Future<void> sendGiroEsqStart()  => sendCommand('\$GTL+');
  Future<void> sendGiroEsqStop()   => sendCommand('\$GTL-');

  // --- Subir / Descer (press/release) ---
  Future<void> sendUpStart()       => sendCommand('\$UPP+');
  Future<void> sendUpStop()        => sendCommand('\$UPP-');
  Future<void> sendDownStart()     => sendCommand('\$DWN+');
  Future<void> sendDownStop()      => sendCommand('\$DWN-');

  // --- Aceleracao (discreto — app envia repetidamente enquanto pressionado) ---
  Future<void> sendAcelPlus()      => sendCommand('\$ACE+');
  Future<void> sendAcelMinus()     => sendCommand('\$ACE-');

  // --- Configuracao pwmHeliceMin ---
  Future<void> sendPwmHelMinPlus()  => sendCommand('\$HMN+');
  Future<void> sendPwmHelMinMinus() => sendCommand('\$HMN-');

  // --- Calibrar bussola ---
  Future<void> sendCalibrate()     => sendCommand('\$CAL');

  Future<void> disconnect() async {
    await _device?.disconnect();
    _device = null;
    _characteristic = null;
    _connectionController.add(false);
  }

  void dispose() {
    _telemetryController.close();
    _connectionController.close();
    _pwmHelMinController.close();
  }
}
