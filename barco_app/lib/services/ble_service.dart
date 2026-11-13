import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import '../models/telemetry.dart';

class RemoteInfo {
  final String code;
  final int batt;
  const RemoteInfo({required this.code, required this.batt});
}

class BatteryInfo {
  final double voltage;
  final int percent;
  const BatteryInfo({required this.voltage, required this.percent});
}

class AdvancedConfig {
  final int calibTimeSeg;
  final int calibPwmGiro;
  final int usoPwmGiro;
  final int aceleracaoIncremento;
  const AdvancedConfig({
    required this.calibTimeSeg,
    required this.calibPwmGiro,
    required this.usoPwmGiro,
    required this.aceleracaoIncremento,
  });
}

/// Ganhos do controle da âncora (Kp: PWM/m, Ki: PWM/(m·s), Kd: PWM/(m/s)).
class AnchorGains {
  final double kp;
  final double ki;
  final double kd;
  const AnchorGains({required this.kp, required this.ki, required this.kd});
  static const defaults = AnchorGains(kp: 60, ki: 5, kd: 30);
}

/// Estado da âncora enviado pelo motor ($ANS) enquanto ela está ativa.
class AnchorStatus {
  final double distance;  // m até o ponto
  final double speed;     // m/s
  final double holdPwm;   // força aprendida contra vento/correnteza (0..160)
  final double holdDir;   // direção em que o motor empurra para segurar (graus)
  final double hdop;
  final bool gpsLost;
  final int throttle;
  const AnchorStatus({
    required this.distance, required this.speed, required this.holdPwm,
    required this.holdDir, required this.hdop, required this.gpsLost,
    required this.throttle,
  });
}

/// Resultado de uma atualização de firmware via BLE.
class OtaResult {
  final bool success;
  final String message;
  const OtaResult(this.success, this.message);
}

/// Nome BLE anunciado pelo módulo do barco.
const kDeviceName = 'PescaPlus';

const _serviceUuid        = '0000ffe0-0000-1000-8000-00805f9b34fb';
const _characteristicUuid = '0000ffe1-0000-1000-8000-00805f9b34fb';
const _otaCharUuid        = '0000ffe2-0000-1000-8000-00805f9b34fb';
const _firmwareManifestUrl = 'https://raw.githubusercontent.com/wilianpasternak/ModuloBarco/main/firmware_latest.json';
const _savedDeviceKey     = 'saved_device_id';

class BleService {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _characteristic;
  BluetoothCharacteristic? _otaCharacteristic;
  String _lineBuffer = '';
  String _firmwareVersion = '0.0.0';

  // Assinaturas da conexão atual — canceladas a cada (re)conexão para não
  // acumular listeners duplicados.
  StreamSubscription<BluetoothConnectionState>? _connStateSub;
  StreamSubscription<List<int>>? _dataSub;
  StreamSubscription<List<int>>? _otaSub;
  Future<bool>? _reconnectFuture;
  bool _otaInProgress = false;
  final _otaMsgController = StreamController<String>.broadcast();

  final _telemetryController      = StreamController<Telemetry>.broadcast();
  final _connectionController     = StreamController<bool>.broadcast();
  final _pwmHelMinController      = StreamController<int>.broadcast();
  final _versionController        = StreamController<String>.broadcast();
  final _otaProgressController    = StreamController<double>.broadcast();
  final _buzzerController         = StreamController<bool>.broadcast();
  final _remotesController        = StreamController<List<RemoteInfo>>.broadcast();
  final _headingOffsetController  = StreamController<int>.broadcast();
  final _remoteRegModeController  = StreamController<bool>.broadcast();
  final _advancedConfigController = StreamController<AdvancedConfig>.broadcast();
  final _batteryController        = StreamController<BatteryInfo>.broadcast();
  final _anchorGainsController    = StreamController<AnchorGains>.broadcast();
  final _anchorStatusController   = StreamController<AnchorStatus>.broadcast();
  final _giroStalledController    = StreamController<bool>.broadcast();
  final _calibrationController    = StreamController<String>.broadcast();
  final _compassStateController   = StreamController<int>.broadcast();
  int _compassState = -1;

  Stream<Telemetry>        get telemetryStream      => _telemetryController.stream;
  Stream<bool>             get connectionStream     => _connectionController.stream;
  Stream<int>              get pwmHelMinStream      => _pwmHelMinController.stream;
  Stream<String>           get versionStream        => _versionController.stream;
  Stream<double>           get otaProgressStream    => _otaProgressController.stream;
  Stream<bool>             get buzzerStream         => _buzzerController.stream;
  Stream<List<RemoteInfo>> get remotesStream        => _remotesController.stream;
  Stream<int>              get headingOffsetStream  => _headingOffsetController.stream;
  Stream<bool>             get remoteRegModeStream  => _remoteRegModeController.stream;
  Stream<AdvancedConfig>   get advancedConfigStream => _advancedConfigController.stream;
  Stream<BatteryInfo>      get batteryStream        => _batteryController.stream;
  Stream<AnchorGains>      get anchorGainsStream    => _anchorGainsController.stream;
  Stream<AnchorStatus>     get anchorStatusStream   => _anchorStatusController.stream;
  /// true quando o motor de giro travou (PWM máximo sem girar); false quando voltou.
  Stream<bool>             get giroStalledStream    => _giroStalledController.stream;
  /// Etapas da calibração da bússola: '1' (girando), '2' (verificando),
  /// 'OK' ou 'ERR:' seguido do motivo.
  Stream<String>           get calibrationStream    => _calibrationController.stream;
  /// Estado da bússola: 1 ok, 0 não calibrada, 2 calibração inválida
  /// (interferência / motor reinstalado), 3 bússola não encontrada.
  Stream<int>              get compassStateStream   => _compassStateController.stream;
  int get compassState => _compassState;
  String get firmwareVersion => _firmwareVersion;

  bool get isConnected => _device != null && (_device!.isConnected);

  /// true enquanto um OTA está em andamento (inclui reinício e reconexão).
  bool get otaInProgress => _otaInProgress;

  // UUID: extrai os 4 chars do campo 16-bit (posicao 4-8 sem tracos)
  // Funciona com forma curta "ffe0" e longa "0000ffe0-0000-1000-8000-00805f9b34fb"
  static bool _uuidMatch(String a, String b) {
    a = a.toLowerCase().replaceAll('-', '');
    b = b.toLowerCase().replaceAll('-', '');
    if (a == b) return true;
    String s(String u) => u.length >= 8 ? u.substring(4, 8) : u;
    return s(a) == s(b);
  }

  Future<void> _cancelConnectionSubs() async {
    await _connStateSub?.cancel();
    await _dataSub?.cancel();
    await _otaSub?.cancel();
    _connStateSub = null;
    _dataSub = null;
    _otaSub = null;
  }

  Future<void> connect(BluetoothDevice device) async {
    await _cancelConnectionSubs();
    _lineBuffer = '';
    try {
      await _connect(device);
    } catch (_) {
      await _cancelConnectionSubs();
      try { await device.disconnect(); } catch (_) {}
      _characteristic = null;
      _otaCharacteristic = null;
      _connectionController.add(false);
      rethrow;
    }
  }

  Future<void> _connect(BluetoothDevice device) async {
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
            _dataSub = c.onValueReceived.listen((value) {
              if (value.isNotEmpty) _onData(value);
            });
          }
          if (_uuidMatch(c.uuid.toString(), _otaCharUuid)) {
            _otaCharacteristic = c;
            await c.setNotifyValue(true);
            _otaSub = c.onValueReceived.listen((value) {
              if (value.isNotEmpty) _onOtaData(value);
            });
          }
        }
      }
    }

    if (_characteristic == null) {
      throw StateError('Serviço do motor não encontrado');
    }

    // Solicita valores de configuração (HMN, VER) — firmware responde com $HMN:XX e $VER:XX
    // Delay necessário: firmware pode ainda não ter processado o evento de conexão
    Future.delayed(const Duration(milliseconds: 700), () => sendCommand('\$CFG?'));
    // Solicita config avancada (inclui incremento de aceleracao, exibido fora da senha)
    Future.delayed(const Duration(milliseconds: 800), () => sendCommand('\$ACG?'));

    _connStateSub = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _characteristic = null;
        _otaCharacteristic = null;
        _dataSub?.cancel();
        _otaSub?.cancel();
        _dataSub = null;
        _otaSub = null;
        _connStateSub?.cancel();
        _connStateSub = null;
        _connectionController.add(false);
      }
    });
  }

  /// Reconecta ao último motor (tentativas a cada ~2 s até [timeout]).
  /// Chamadas simultâneas compartilham a mesma tentativa.
  Future<bool> reconnect({Duration timeout = const Duration(seconds: 30)}) {
    return _reconnectFuture ??= _reconnectLoop(timeout)
        .whenComplete(() => _reconnectFuture = null);
  }

  Future<bool> _reconnectLoop(Duration timeout) async {
    final savedId = _device?.remoteId.str ?? await getSavedDeviceId();
    if (savedId == null) return false;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (isConnected && _characteristic != null) return true;
      try {
        BluetoothDevice? target;
        for (final d in FlutterBluePlus.connectedDevices) {
          if (d.remoteId.str == savedId) { target = d; break; }
        }
        target ??= BluetoothDevice(remoteId: DeviceIdentifier(savedId));
        await connect(target);
        return true;
      } catch (_) {
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    return false;
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
      } else if (line.startsWith('\$HOF:')) {
        final val = int.tryParse(line.substring(5));
        if (val != null) _headingOffsetController.add(val);
      } else if (line.startsWith('\$RGM:')) {
        final val = int.tryParse(line.substring(5));
        if (val != null) _remoteRegModeController.add(val == 1);
      } else if (line.startsWith('\$ACG:')) {
        final parts = line.substring(5).split(':');
        if (parts.length >= 3) {
          final cfg = AdvancedConfig(
            calibTimeSeg: int.tryParse(parts[0]) ?? 10,
            calibPwmGiro: int.tryParse(parts[1]) ?? 160,
            usoPwmGiro:   int.tryParse(parts[2]) ?? 240,
            aceleracaoIncremento: parts.length >= 4 ? (int.tryParse(parts[3]) ?? 5) : 5,
          );
          _advancedConfigController.add(cfg);
        }
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
      } else if (line.startsWith('\$APG:')) {
        final p = line.substring(5).split(':').map(int.tryParse).toList();
        if (p.length >= 3 && !p.contains(null)) {
          _anchorGainsController.add(AnchorGains(kp: p[0]! / 10, ki: p[1]! / 10, kd: p[2]! / 10));
        }
      } else if (line.startsWith('\$BSC:')) {
        final v = int.tryParse(line.substring(5).trim());
        if (v != null) { _compassState = v; _compassStateController.add(v); }
      } else if (line.startsWith('\$CAL:')) {
        _calibrationController.add(line.substring(5).trim());
      } else if (line.startsWith('\$GTV:')) {
        _giroStalledController.add(line.substring(5).trim() == '1');
      } else if (line.startsWith('\$ANS:')) {
        final p = line.substring(5).split(':');
        if (p.length >= 7) {
          final v = p.map(double.tryParse).toList();
          if (!v.contains(null)) {
            _anchorStatusController.add(AnchorStatus(
              distance: v[0]!, speed: v[1]!, holdPwm: v[2]!, holdDir: v[3]!,
              hdop: v[4]!, gpsLost: v[5]! != 0, throttle: v[6]!.round(),
            ));
          }
        }
      } else if (line.startsWith('\$BAT:')) {
        final parts = line.substring(5).split(':');
        if (parts.length >= 2) {
          final v = double.tryParse(parts[0]);
          final p = int.tryParse(parts[1]);
          if (v != null && p != null) _batteryController.add(BatteryInfo(voltage: v, percent: p));
        }
      } else if (line.startsWith('\$')) {
        final t = Telemetry.fromLine(line);
        if (t != null) _telemetryController.add(t);
      }
    }
  }

  void _onOtaData(List<int> bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    for (final raw in text.split('\n')) {
      final msg = raw.trim();
      if (msg.isEmpty) continue;
      if (msg.startsWith('OTA_ACK:')) {
        final received = int.tryParse(msg.substring(8)) ?? 0;
        _otaProgressController.add(received.toDouble());
      }
      _otaMsgController.add(msg);
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

  // --- Controles NRF: solicitar lista e modo de cadastro ---
  Future<void> sendRequestRemotes()    => sendCommand('\$RQL');
  Future<void> sendRemoteRegEnable()   => sendCommand('\$RGE');
  Future<void> sendRemoteRegDisable()  => sendCommand('\$RGD');

  // --- Configurações avançadas ---
  Future<void> sendRequestAdvancedConfig()    => sendCommand('\$ACG?');
  Future<void> sendCalibTimeSeg(int seconds)  => sendCommand('\$CAT:$seconds');
  Future<void> sendCalibPwmGiro(int pwm)      => sendCommand('\$CAP:$pwm');
  Future<void> sendUsoPwmGiro(int pwm)        => sendCommand('\$GUP:$pwm');
  Future<void> sendAceleracaoIncremento(int valor) => sendCommand('\$INC:$valor');

  // --- Ganhos da âncora (ajuste fino; o firmware recebe valores x10) ---
  Future<void> sendRequestAnchorGains() => sendCommand('\$APG?');
  Future<void> sendAnchorKp(double v) => sendCommand('\$APK:${(v * 10).round()}');
  Future<void> sendAnchorKi(double v) => sendCommand('\$API:${(v * 10).round()}');
  Future<void> sendAnchorKd(double v) => sendCommand('\$APD:${(v * 10).round()}');
  Future<void> sendAnchorGainsReset() => sendCommand('\$APR');

  // --- Offset de heading da âncora ---
  Future<void> sendHeadingOffset(int deg) => sendCommand('\$HOF:$deg');

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
      final resp = await http.get(Uri.parse(_firmwareManifestUrl))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final version = data['version'] as String?;
      final url     = data['url']     as String?;
      if (version == null || url == null) return {'version': null, 'url': null};
      return {'version': version, 'url': url};
    } catch (_) {
      return null;
    }
  }

  // --- OTA firmware update over BLE ---
  //
  // Fluxo: baixa o .bin → OTA_START (espera OTA_READY) → chunks → OTA_END
  // (espera OTA_OK: o motor validou tamanho, MD5 e assinatura) → motor
  // reinicia → reconecta sozinho → confere a versão informada pelo motor.
  // Se a versão não bater, o firmware novo não subiu e o bootloader voltou
  // para a versão anterior (rollback).
  Future<OtaResult> performOta(
    String firmwareUrl,
    String expectedVersion, {
    required void Function(double) onProgress,
    required void Function(String) onStatus,
  }) async {
    if (_otaCharacteristic == null || _device == null) {
      return const OtaResult(false, 'Sem conexão com o motor.');
    }
    _otaInProgress = true;
    try {
      onStatus('Baixando firmware...');
      final resp = await http.get(Uri.parse(firmwareUrl))
          .timeout(const Duration(seconds: 60));
      if (resp.statusCode != 200) {
        return OtaResult(false, 'Falha ao baixar o firmware (HTTP ${resp.statusCode}).');
      }
      final bytes = resp.bodyBytes;
      final totalSize = bytes.length;
      final md5sum = md5.convert(bytes).toString();
      final device = _device!;

      // Chunk = MTU - 3 bytes de overhead ATT (iOS sem requestMtu negocia ~185)
      final mtu = await device.mtu.first;
      final chunkSize = (mtu - 3).clamp(20, 512);

      // 1) Início — espera o motor abrir a partição
      onStatus('Preparando o motor...');
      final ready = _waitOtaMessage(
          (m) => m == 'OTA_READY' || m.startsWith('OTA_ERR'), const Duration(seconds: 10));
      await _otaCharacteristic!.write(
          utf8.encode('OTA_START:$totalSize:$expectedVersion:$md5sum\n'),
          withoutResponse: false);
      final r = await ready;
      if (r == null) return const OtaResult(false, 'O motor não respondeu ao início da atualização.');
      if (r.startsWith('OTA_ERR')) return OtaResult(false, _otaErrorText(r));

      // 2) Envio — sem resposta (rápido); o motor aplica controle de fluxo
      onStatus('Enviando firmware...');
      String? motorError;
      final errSub = _otaMsgController.stream
          .where((m) => m.startsWith('OTA_ERR'))
          .listen((m) => motorError = m);
      try {
        int offset = 0;
        int chunkNum = 0;
        while (offset < totalSize) {
          if (motorError != null) return OtaResult(false, _otaErrorText(motorError!));
          if (!isConnected || _otaCharacteristic == null) {
            return const OtaResult(false, 'Conexão perdida durante o envio. O motor continua na versão atual.');
          }
          final end = (offset + chunkSize > totalSize) ? totalSize : offset + chunkSize;
          await _otaCharacteristic!.write(bytes.sublist(offset, end), withoutResponse: true);
          offset = end;
          chunkNum++;
          onProgress(offset / totalSize);
          // Pausa a cada 20 pacotes para não saturar o buffer BLE
          if (chunkNum % 20 == 0) {
            await Future.delayed(const Duration(milliseconds: 30));
          }
        }
        await Future.delayed(const Duration(milliseconds: 300));
        if (motorError != null) return OtaResult(false, _otaErrorText(motorError!));
      } finally {
        await errSub.cancel();
      }

      // 3) Fim — motor valida tamanho, MD5 e assinatura antes de aceitar
      onStatus('Verificando firmware no motor...');
      final done = _waitOtaMessage(
          (m) => m == 'OTA_OK' || m.startsWith('OTA_ERR'), const Duration(seconds: 20));
      await _otaCharacteristic!.write(utf8.encode('OTA_END\n'), withoutResponse: false);
      final e = await done;
      if (e == null) return const OtaResult(false, 'O motor não confirmou o recebimento do firmware.');
      if (e.startsWith('OTA_ERR')) return OtaResult(false, _otaErrorText(e));

      // 4) Reinício e reconexão automática
      onStatus('Firmware aceito. Reiniciando o motor...');
      await _waitDisconnected(device, const Duration(seconds: 8));
      await Future.delayed(const Duration(seconds: 2));

      onStatus('Reconectando ao motor...');
      final version = await _reconnectAndGetVersion(const Duration(seconds: 45));
      if (version == null) {
        return const OtaResult(false,
            'Firmware enviado, mas não foi possível reconectar ao motor. '
            'Verifique se ele ligou e conecte manualmente.');
      }
      if (version != expectedVersion) return _rollbackResult(version);

      // 5) O firmware novo se confirma após ~10 s rodando sem falhas. Se ele
      //    reiniciar nesse intervalo, o bootloader volta para a versão anterior.
      onStatus('Validando o novo firmware...');
      final dropped = await _waitDisconnected(_device!, const Duration(seconds: 12));
      if (dropped) {
        onStatus('Reconectando ao motor...');
        final v2 = await _reconnectAndGetVersion(const Duration(seconds: 45));
        if (v2 == null) {
          return const OtaResult(false,
              'O motor reiniciou após a atualização e não reconectou. Conecte manualmente.');
        }
        if (v2 != expectedVersion) return _rollbackResult(v2);
      }
      return OtaResult(true, 'Atualização concluída! Motor na versão v$expectedVersion.');
    } on TimeoutException {
      return const OtaResult(false, 'Tempo esgotado durante a atualização.');
    } catch (e) {
      return OtaResult(false, 'Falha na atualização: $e');
    } finally {
      _otaInProgress = false;
    }
  }

  OtaResult _rollbackResult(String version) => OtaResult(false,
      'O firmware novo não iniciou corretamente e o motor voltou '
      'automaticamente para a versão v$version.');

  Future<String?> _waitOtaMessage(bool Function(String) test, Duration timeout) async {
    try {
      return await _otaMsgController.stream.firstWhere(test).timeout(timeout);
    } catch (_) {
      return null;
    }
  }

  /// Espera a desconexão; retorna true se desconectou dentro do prazo.
  Future<bool> _waitDisconnected(BluetoothDevice device, Duration timeout) async {
    if (!device.isConnected) return true;
    try {
      await device.connectionState
          .firstWhere((s) => s == BluetoothConnectionState.disconnected)
          .timeout(timeout);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Reconecta e devolve a versão informada pelo motor ($VER), ou null.
  Future<String?> _reconnectAndGetVersion(Duration timeout) async {
    final versionFuture = versionStream.first
        .timeout(timeout + const Duration(seconds: 10))
        .then<String?>((v) => v)
        .catchError((_) => null);
    if (!await reconnect(timeout: timeout)) return null;
    // connect() já pede $CFG?; reforça caso a primeira resposta se perca
    Future.delayed(const Duration(seconds: 2), () => sendCommand('\$CFG?'));
    return versionFuture;
  }

  static String _otaErrorText(String msg) {
    final reason = msg.startsWith('OTA_ERR:') ? msg.substring(8) : msg;
    switch (reason) {
      case 'invalid signature':
        return 'Firmware recusado: assinatura inválida.';
      case 'wrong firmware':
        return 'Firmware recusado: o arquivo não é do Pesca Plus.';
      case 'not an ESP32 image':
        return 'Firmware recusado: arquivo inválido.';
      case 'md5 mismatch':
        return 'Firmware corrompido na transferência. Tente novamente.';
      case 'size mismatch':
      case 'too much data':
        return 'Transferência incompleta. Tente novamente.';
      case 'invalid size':
        return 'Firmware grande demais para o motor.';
      case 'begin failed':
        return 'O motor não conseguiu iniciar a atualização. Aguarde alguns segundos e tente novamente.';
      default:
        return 'Erro no motor durante a atualização ($reason).';
    }
  }

  Future<void> disconnect() async {
    await _cancelConnectionSubs();
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
    _otaMsgController.close();
    _anchorGainsController.close();
    _anchorStatusController.close();
    _giroStalledController.close();
    _calibrationController.close();
    _compassStateController.close();
    _cancelConnectionSubs();
    _buzzerController.close();
    _remotesController.close();
    _headingOffsetController.close();
    _remoteRegModeController.close();
    _advancedConfigController.close();
    _batteryController.close();
  }
}
