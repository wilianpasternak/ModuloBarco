import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import '../models/telemetry.dart';

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

  Stream<Telemetry> get telemetryStream   => _telemetryController.stream;
  Stream<bool>      get connectionStream  => _connectionController.stream;
  Stream<int>       get pwmHelMinStream   => _pwmHelMinController.stream;
  Stream<String>    get versionStream     => _versionController.stream;
  Stream<double>    get otaProgressStream => _otaProgressController.stream;
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

    await BleService.saveDevice(device.remoteId.str);
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

  // --- Calibrar bussola ---
  Future<void> sendCalibrate()     => sendCommand('\$CAL');

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
  Future<Map<String, dynamic>?> checkForUpdate() async {
    try {
      final resp = await http.get(Uri.parse(_githubReleasesApi),
          headers: {'Accept': 'application/vnd.github.v3+json'});
      if (resp.statusCode != 200) return null;
      final json = resp.body;
      final tagMatch = RegExp(r'"tag_name":"([^"]+)"').firstMatch(json);
      final urlMatch = RegExp(r'"browser_download_url":"([^"]+\.bin)"').firstMatch(json);
      if (tagMatch == null || urlMatch == null) return null;
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
    if (_otaCharacteristic == null) return false;
    try {
      // Download firmware binary
      final resp = await http.get(Uri.parse(firmwareUrl));
      if (resp.statusCode != 200) return false;
      final bytes = resp.bodyBytes;
      final totalSize = bytes.length;

      // Send OTA_START command
      final startCmd = utf8.encode('OTA_START:$totalSize:new\n');
      await _otaCharacteristic!.write(startCmd, withoutResponse: false);

      // Wait for OTA_READY acknowledgement
      await Future.delayed(const Duration(milliseconds: 500));

      // Send firmware in chunks
      const chunkSize = 512;
      int offset = 0;
      while (offset < totalSize) {
        final end = (offset + chunkSize > totalSize) ? totalSize : offset + chunkSize;
        final chunk = bytes.sublist(offset, end);
        await _otaCharacteristic!.write(chunk, withoutResponse: false);
        offset = end;
        onProgress(offset / totalSize);
        // Small delay every 32 chunks to avoid overwhelming BLE buffer
        if ((offset ~/ chunkSize) % 32 == 0) {
          await Future.delayed(const Duration(milliseconds: 10));
        }
      }

      // Finalise OTA
      await _otaCharacteristic!.write(utf8.encode('OTA_END\n'), withoutResponse: false);
      await Future.delayed(const Duration(seconds: 2));
      return true;
    } catch (e) {
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
  }
}
