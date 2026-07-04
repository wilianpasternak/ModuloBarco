import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../services/ble_service.dart';
import '../models/telemetry.dart';
import 'remote_screen.dart';
import 'map_screen.dart';
import 'settings_screen.dart';
import 'scan_screen.dart';

const _kGold    = Color(0xFFD4A800);
const _kGoldDim = Color(0xFF6B5400);
const _kDark    = Color(0xFF0F0F08);
const _kPanel   = Color(0xFF1A1A10);

class AppShell extends StatefulWidget {
  final BleService ble;
  final bool autoReconnect;
  const AppShell({super.key, required this.ble, this.autoReconnect = false});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedIndex = 0;
  Telemetry? _tel;
  StreamSubscription? _telSub;
  StreamSubscription? _connSub;
  StreamSubscription? _hmnSub;
  bool _isConnected = true;
  bool _isReconnecting = false;
  bool _manualDisconnect = false;
  int _pwmHelMin = 0;

  static const _tabLabels = ['Controle', 'Mapa', 'Config'];
  static const _tabIcons  = [Icons.sports_esports, Icons.map, Icons.settings];

  @override
  void initState() {
    super.initState();
    _isConnected = !widget.autoReconnect;
    _telSub  = widget.ble.telemetryStream.listen((t) => setState(() => _tel = t));
    _connSub = widget.ble.connectionStream.listen(_onConnectionChange);
    _hmnSub  = widget.ble.pwmHelMinStream.listen((v) => setState(() => _pwmHelMin = v));
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
    if (!connected) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Conexão com o motor perdida',
            style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.red.withValues(alpha: 0.85),
      ));
    }
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
    try {
      final known = FlutterBluePlus.connectedDevices;
      BluetoothDevice? target;
      for (final d in known) {
        if (d.remoteId.str == savedId) { target = d; break; }
      }
      target ??= BluetoothDevice(remoteId: DeviceIdentifier(savedId));
      await widget.ble.connect(target);
      if (mounted) setState(() { _isConnected = true; _isReconnecting = false; });
    } catch (_) {
      if (mounted) {
        setState(() { _isReconnecting = false; _isConnected = false; });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text(
            'Motor não encontrado. Verifique se está ligado e toque em wifi para tentar novamente.',
            style: TextStyle(color: Colors.white),
          ),
          backgroundColor: Colors.red.withValues(alpha: 0.85),
          duration: const Duration(seconds: 5),
        ));
      }
    }
  }

  @override
  void dispose() {
    _telSub?.cancel();
    _connSub?.cancel();
    _hmnSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      RemoteScreen(ble: widget.ble, tel: _tel),
      MapScreen(ble: widget.ble, tel: _tel),
      SettingsScreen(ble: widget.ble, initialPwmHelMin: _pwmHelMin),
    ];

    return Stack(
      children: [
        Scaffold(
          backgroundColor: _kDark,
          appBar: AppBar(
            backgroundColor: _kPanel,
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset('assets/logo_braga_pesca.png', height: 28),
                const SizedBox(width: 10),
                const Text('Braga Pesca',
                    style: TextStyle(color: _kGold, fontSize: 16,
                        fontWeight: FontWeight.bold, letterSpacing: 1)),
              ],
            ),
            centerTitle: true,
            actions: [
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
                children: List.generate(3, (i) => Expanded(
                  child: InkWell(
                    onTap: () => setState(() => _selectedIndex = i),
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
                    Image.asset('assets/logo_braga_pesca.png', height: 70),
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
