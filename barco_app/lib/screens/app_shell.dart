import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../services/ble_service.dart';
import '../models/telemetry.dart';
import 'remote_screen.dart';
import 'map_screen.dart';
import 'community_screen.dart';
import 'settings_screen.dart';
import 'scan_screen.dart';

const _kGold    = Color(0xFFD4A800);
const _kGoldDim = Color(0xFF6B5400);
const _kDark    = Color(0xFF0F0F08);
const _kPanel   = Color(0xFF1A1A10);

class AppShell extends StatefulWidget {
  final BleService ble;
  final bool autoReconnect;
  final bool startOffline;
  const AppShell({super.key, required this.ble, this.autoReconnect = false, this.startOffline = false});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedIndex = 0;
  Telemetry? _tel;
  StreamSubscription? _telSub;
  StreamSubscription? _connSub;
  StreamSubscription? _hmnSub;
  StreamSubscription? _batSub;
  StreamSubscription? _giroSub;
  StreamSubscription? _compassSub;
  int _lastCompassState = -1;
  bool _lastCompassStateWasBad = false;
  bool _isConnected = true;
  bool _isReconnecting = false;
  bool _manualDisconnect = false;
  bool _autoReconnecting = false;
  int _pwmHelMin = 0;
  BatteryInfo? _battery;
  final _otaRunning = ValueNotifier<bool>(false);

  static const _tabLabels = ['Controle', 'Mapa', 'Comunidade', 'Config'];
  static const _tabIcons  = [Icons.sports_esports, Icons.map, Icons.groups, Icons.settings];

  @override
  void initState() {
    super.initState();
    _isConnected = !widget.autoReconnect && !widget.startOffline;
    _telSub  = widget.ble.telemetryStream.listen((t) => setState(() => _tel = t));
    _connSub = widget.ble.connectionStream.listen(_onConnectionChange);
    _hmnSub  = widget.ble.pwmHelMinStream.listen((v) => setState(() => _pwmHelMin = v));
    _batSub  = widget.ble.batteryStream.listen((b) => setState(() => _battery = b));
    _compassSub = widget.ble.compassStateStream.listen((st) {
      if (!mounted) return;
      final changed = st != _lastCompassState;
      _lastCompassState = st;
      switch (st) {
        case 0:
          _showSnack('Bússola não calibrada: âncora, norte e aponta-norte ficam bloqueados. '
              'Calibre em Config → Calibrar Bússola.', Colors.orange.shade800, seconds: 6);
          break;
        case 2:
          _showSnack('Calibração da bússola inválida (interferência magnética ou motor reinstalado). '
              'Modos automáticos desligados — recalibre a bússola.', Colors.red, seconds: 7);
          break;
        case 3:
          _showSnack('Bússola não encontrada: verifique a ligação. Modos automáticos bloqueados.',
              Colors.red, seconds: 6);
          break;
        case 1:
          if (changed && _lastCompassStateWasBad) _showSnack('Bússola OK.', Colors.green.shade700);
          break;
      }
      _lastCompassStateWasBad = st != 1;
    });
    _giroSub = widget.ble.giroStalledStream.listen((stalled) {
      if (!mounted) return;
      if (stalled) {
        _showSnack('Motor de giro travado: o motor não consegue girar (cabo enroscado, '
            'obstáculo ou mato na hélice). Nova tentativa em 5 s.', Colors.red, seconds: 6);
      } else {
        _showSnack('Motor de giro voltou a girar.', Colors.green.shade700);
      }
    });
    _otaRunning.addListener(() { if (mounted) setState(() {}); });
    if (widget.autoReconnect) {
      _scheduleReconnect();
    }
  }

  Future<void> _scheduleReconnect() async {
    try {
      await FlutterBluePlus.adapterState
          .where((s) => s == BluetoothAdapterState.on)
          .first
          .timeout(const Duration(seconds: 10));
      await Future.delayed(const Duration(milliseconds: 300));
    } catch (_) {
      await Future.delayed(const Duration(milliseconds: 600));
    }
    if (mounted) _reconnect();
  }

  void _onConnectionChange(bool connected) {
    if (!mounted) return;
    if (!connected && _manualDisconnect) {
      _manualDisconnect = false;
      setState(() { _isConnected = false; _tel = null; });
      return;
    }
    setState(() {
      _isConnected = connected;
      if (!connected) _tel = null;
    });
    // Durante o OTA o próprio fluxo de atualização cuida da reconexão
    if (!connected && !widget.ble.otaInProgress && !_isReconnecting) {
      _autoReconnect();
    }
  }

  /// Queda inesperada: tenta reconectar sozinho, sem bloquear a tela.
  Future<void> _autoReconnect() async {
    if (_autoReconnecting) return;
    _autoReconnecting = true;
    _showSnack('Conexão com o motor perdida — reconectando...', Colors.orange);
    final ok = await widget.ble.reconnect(timeout: const Duration(seconds: 60));
    _autoReconnecting = false;
    if (!mounted) return;
    if (ok) {
      setState(() => _isConnected = true);
      _showSnack('Reconectado ao motor.', Colors.green.shade700);
    } else if (!widget.ble.isConnected) {
      _showSnack('Motor não encontrado. Toque no ícone de conexão para tentar novamente.',
          Colors.red, seconds: 5);
    }
  }

  void _showSnack(String text, Color color, {int seconds = 3}) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(text, style: const TextStyle(color: Colors.white)),
      backgroundColor: color.withValues(alpha: 0.9),
      duration: Duration(seconds: seconds),
    ));
  }

  Future<void> _disconnect() async {
    _manualDisconnect = true;
    await widget.ble.disconnect();
  }

  Future<void> _reconnect() async {
    if (_isReconnecting) return;
    final savedId = await BleService.getSavedDeviceId();
    if (savedId == null) {
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const ScanScreen()),
        );
      }
      return;
    }
    if (mounted) setState(() => _isReconnecting = true);
    final ok = await widget.ble.reconnect(timeout: const Duration(seconds: 15));
    if (!mounted) return;
    setState(() { _isReconnecting = false; _isConnected = ok; });
    if (!ok) {
      _showSnack('Motor não encontrado. Verifique se está ligado e toque no ícone de conexão para tentar novamente.',
          Colors.red, seconds: 5);
    }
  }

  @override
  void dispose() {
    _telSub?.cancel();
    _connSub?.cancel();
    _hmnSub?.cancel();
    _batSub?.cancel();
    _giroSub?.cancel();
    _compassSub?.cancel();
    _otaRunning.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      RemoteScreen(ble: widget.ble, tel: _tel),
      MapScreen(ble: widget.ble, tel: _tel),
      const CommunityScreen(),
      SettingsScreen(ble: widget.ble, initialPwmHelMin: _pwmHelMin, otaRunning: _otaRunning),
    ];

    return Stack(
      children: [
        Scaffold(
          backgroundColor: _kDark,
          appBar: AppBar(
            backgroundColor: _kPanel,
            title: const Text('Pesca Plus',
                style: TextStyle(color: _kGold, fontSize: 16,
                    fontWeight: FontWeight.bold, letterSpacing: 1)),
            centerTitle: true,
            actions: [
              if (_battery != null) _BatteryWidget(info: _battery!),
              IconButton(
                icon: Icon(
                  _isConnected ? Icons.wifi : Icons.wifi_off,
                  color: _isConnected ? Colors.green.shade400 : Colors.red.shade400,
                ),
                tooltip: _isConnected ? 'Desconectar' : 'Conectar',
                onPressed: _isReconnecting
                    ? null
                    : (_isConnected ? _disconnect : _reconnect),
              ),
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(48),
              child: Row(
                children: List.generate(4, (i) => Expanded(
                  child: InkWell(
                    onTap: () {
                      if (_otaRunning.value) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text('Atualização de firmware em andamento. Aguarde o término.',
                              style: TextStyle(color: Colors.white)),
                          backgroundColor: Colors.orange,
                          duration: Duration(seconds: 2),
                        ));
                        return;
                      }
                      setState(() => _selectedIndex = i);
                      if (i == 3) widget.ble.sendRequestRemotes();
                    },
                    child: Container(
                      height: 48,
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: _selectedIndex == i ? _kGold : Colors.transparent,
                            width: 2,
                          ),
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(_tabIcons[i],
                              color: _selectedIndex == i ? _kGold : _kGoldDim, size: 20),
                          Text(_tabLabels[i],
                              style: TextStyle(
                                color: _selectedIndex == i ? _kGold : _kGoldDim,
                                fontSize: 10,
                              )),
                        ],
                      ),
                    ),
                  ),
                )),
              ),
            ),
          ),
          body: IndexedStack(index: _selectedIndex, children: screens),
        ),
        if (_isReconnecting)
          Container(
            color: Colors.black.withValues(alpha: 0.75),
            child: Center(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 40),
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: _kPanel,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _kGold, width: 2),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset('assets/logo_pescaplus.png', height: 70),
                    const SizedBox(height: 20),
                    const CircularProgressIndicator(color: _kGold),
                    const SizedBox(height: 16),
                    const Text('Conectando ao motor...',
                        style: TextStyle(color: _kGold, fontSize: 15,
                            fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _BatteryWidget extends StatelessWidget {
  final BatteryInfo info;
  const _BatteryWidget({required this.info});

  Color _color() {
    if (info.percent >= 60) return Colors.green.shade400;
    if (info.percent >= 20) return Colors.orange.shade400;
    return Colors.red.shade400;
  }

  IconData _icon() {
    if (info.percent >= 90) return Icons.battery_full;
    if (info.percent >= 70) return Icons.battery_6_bar;
    if (info.percent >= 50) return Icons.battery_4_bar;
    if (info.percent >= 30) return Icons.battery_3_bar;
    if (info.percent >= 10) return Icons.battery_1_bar;
    return Icons.battery_alert;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_icon(), color: _color(), size: 20),
          const SizedBox(width: 2),
          Text(
            '${info.voltage.toStringAsFixed(1)}V',
            style: TextStyle(color: _color(), fontSize: 12, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}
