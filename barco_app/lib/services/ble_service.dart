import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import '../models/telemetry.dart';

class RemoteInfo {
  final String code;
  final int batt;
  const RemoteInfo({required this.code, required this.batt});
}

const _serviceUuid        = '0000ffe0-0000-1000-8000-00805f9b34fb';
const _characteristicUuid = '0000ffe1-0000-1000-8000-00805f9b34fb';
const _otaCharUuid        = '0000ffe2-0000-1000-8000-00805f9b34fb';
const _githubReleasesApi  = 'https://api.github.com/repos/wilianpasternak/ModuloBarco/releases/latest';
const _savedDeviceKey     = 'saved_device_id';

class BleService {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _characteristic;
  BluetoothCharacteristic? _otaCharacteristic;
  String _lineBuffer = '';
  String _firmwareVersion = '0.0.0';

  final _telemetryController   = StreamController<Telemetry>.broadcast();
  final _connectionController  = StreamController<bool>.broadcast();
  final _pwmHelMinController   = StreamController<int>.broadcast();
  final _versionController     = StreamController<String>.broadcast();
  final _otaProgressController = StreamController<double>.broadcast();
  final _buzzerController      = StreamController<bool>.broadcast();
  final _remotesController     = StreamController<List<RemoteInfo>>.broadcast();

  Stream<Telemetry>        get telemetryStream   => _telemetryController.stream;
  Stream<bool>             get connectionStream  => _connectionController.stream;
  Stream<int>              get pwmHelMinStream   => _pwmHelMinController.stream;
  Stream<String>           get versionStream     => _versionController.stream;
  Stream<double>           get otaProgressStream => _otaProgressController.stream;
  Stream<bool>             get buzzerStream      => _buzzerController.stream;
  Stream<List<RemoteInfo>> get remotesStream     => _remotesController.stream;
  String get firmwareVersion => _firmwareVersion;

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

    // Salva imediatamente após conexão, antes de discoverServices() que pode falhar
    await BleService.saveDevice(device.remoteId.str);

    // Solicita MTU máximo em ambas as plataformas
    // Android: obrigatório via requestMtu; iOS: negocia automaticamente mas requestMtu acelera o processo
    try { await device.requestMtu(512); } catch (_) {}  // iOS pode lançar exceção em alguns casos

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
          }
          if (_uuidMatch(c.uuid.toString(), _otaCharUuid)) {
            _otaCharacteristic = c;
            await c.setNotifyValue(true);
            c.lastValueStream.listen((value) {
              if (value.isNotEmpty) _onOtaData(value);
            });
          }
        }
      }
    }

    // Solicita valores de configuração (HMN, VER) — firmware responde com $HMN:XX e $VER:XX
    // Delay necessário: firmware pode ainda não ter processado o evento de conexão
    Future.delayed(const Duration(milliseconds: 700), () => sendCommand('\$CFG?'));

    device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _characteristic = null;
        _otaCharacteristic = null;
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
      } else if (line.startsWith('\$VER:')) {
        _firmwareVersion = line.substring(5);
        _versionController.add(_firmwareVersion);
      } else if (line.startsWith('\$BUZ:')) {
        final val = int.tryParse(line.substring(5));
        if (val != null) _buzzerController.add(val == 1);
      } else if (line.startsWith('\$REM:')) {
        final remotes = <RemoteInfo>[];
        final parts = line.substring(5).split(',');
        for (final p in parts) {
          final idx = p.indexOf(':');
          if (idx < 0) continue;
          final code = p.substring(0, idx);
          final batt = int.tryParse(p.substring(idx + 1)) ?? -1;
          if (code != '00000') remotes.add(RemoteInfo(code: code, batt: batt));
        }
        _remotesController.add(remotes);
      } else if (line.startsWith('\$')) {
        final t = Telemetry.fromLine(line);
        if (t != null) _telemetryController.add(t);
      }
    }
  }

  void _onOtaData(List<int> bytes) {
    final msg = utf8.decode(bytes, allowMalformed: true).trim();
    if (msg.startsWith('OTA_ACK:')) {
      final received = int.tryParse(msg.substring(8)) ?? 0;
      _otaProgressController.add(received.toDouble());
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

  // --- Buzzer ---
  Future<void> sendBuzzerOn()      => sendCommand('\$BUZ1');
  Future<void> sendBuzzerOff()     => sendCommand('\$BUZ0');

  // --- Remover controle NRF (code = código de 5 dígitos) ---
  Future<void> sendRemoveRemote(String code) => sendCommand('\$RMC:$code');

  // --- Calibrar bussola ---
  Future<void> sendCalibrate()     => sendCommand('\$CAL');

  // --- Aponta Norte (calibracao): gira para 0° com PWM 120 e histerese 5° ---
  Future<void> sendApontarNorte()  => sendCommand('\$APN');
  Future<void> sendPararNorte()    => sendCommand('\$APN-');

  // --- Saved device ---
  static Future<void> saveDevice(String remoteId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_savedDeviceKey, remoteId);
  }

  static Future<String?> getSavedDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_savedDeviceKey);
  }

  static Future<void> clearSavedDevice() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_savedDeviceKey);
  }

  // --- GitHub OTA check ---
  // Retorna:
  //   null                          → erro de rede
  //   {'version': null, 'url': null} → sem releases publicadas (404)
  //   {'version': '1.x', 'url': '...'} → release encontrada
  Future<Map<String, dynamic>?> checkForUpdate() async {
    try {
      final resp = await http.get(Uri.parse(_githubReleasesApi),
          headers: {'Accept': 'application/vnd.github.v3+json'});
      if (resp.statusCode == 404) return {'version': null, 'url': null};
      if (resp.statusCode != 200) return null;
      final json = resp.body;
      final tagMatch = RegExp(r'"tag_name":"([^"]+)"').firstMatch(json);
      final urlMatch = RegExp(r'"browser_download_url":"([^"]+\.bin)"').firstMatch(json);
      if (tagMatch == null || urlMatch == null) return {'version': null, 'url': null};
      return {
        'version': tagMatch.group(1)!.replaceFirst('v', ''),
        'url': urlMatch.group(1)!,
      };
    } catch (_) {
      return null;
    }
  }

  // --- OTA firmware update over BLE ---
  Future<bool> performOta(String firmwareUrl, void Function(double) onProgress) async {
    if (_otaCharacteristic == null || _device == null) return false;
    try {
      // Download firmware binary
      final resp = await http.get(Uri.parse(firmwareUrl));
      if (resp.statusCode != 200) return false;
      final bytes = resp.bodyBytes;
      final totalSize = bytes.length;

      // Chunk size = MTU - 3 bytes ATT overhead (safe para iOS e Android)
      // iOS sem requestMtu negocia ~185 → max write 182 bytes
      final mtu = await _device!.mtu.first;
      final chunkSize = (mtu - 3).clamp(20, 512);

      // Comando OTA_START com resposta (confiabilidade)
      final startCmd = utf8.encode('OTA_START:$totalSize:new\n');
      await _otaCharacteristic!.write(startCmd, withoutResponse: false);
      await Future.delayed(const Duration(milliseconds: 600));

      // Envia chunks sem resposta (mais rápido; NimBLE bufferiza)
      int offset = 0;
      int chunkNum = 0;
      while (offset < totalSize) {
        final end = (offset + chunkSize > totalSize) ? totalSize : offset + chunkSize;
        final chunk = bytes.sublist(offset, end);
        await _otaCharacteristic!.write(chunk, withoutResponse: true);
        offset = end;
        chunkNum++;
        onProgress(offset / totalSize);
        // Controle de fluxo: pausa a cada 20 pacotes para não saturar o buffer BLE
        if (chunkNum % 20 == 0) {
          await Future.delayed(const Duration(milliseconds: 30));
        }
      }

      // Aguarda o firmware processar os últimos chunks
      await Future.delayed(const Duration(milliseconds: 300));

      // Comando OTA_END com resposta (confiabilidade)
      await _otaCharacteristic!.write(utf8.encode('OTA_END\n'), withoutResponse: false);
      await Future.delayed(const Duration(seconds: 3));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> disconnect() async {
    await _device?.disconnect();
    _device = null;
    _characteristic = null;
    _otaCharacteristic = null;
    _connectionController.add(false);
  }

  void dispose() {
    _telemetryController.close();
    _connectionController.close();
    _pwmHelMinController.close();
    _versionController.close();
    _otaProgressController.close();
    _buzzerController.close();
    _remotesController.close();
  }
}
