import 'dart:async';
import 'package:flutter/material.dart';
import '../services/ble_service.dart';
import '../models/telemetry.dart';
import 'remote_screen.dart';
import 'map_screen.dart';
import 'settings_screen.dart';
import 'scan_screen.dart';

class AppShell extends StatefulWidget {
  final BleService ble;
  const AppShell({super.key, required this.ble});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedIndex = 0;
  Telemetry? _tel;
  StreamSubscription? _telSub;
  StreamSubscription? _connSub;

  static const _tabLabels = ['Controle', 'Mapa', 'Config'];
  static const _tabIcons  = [Icons.sports_esports, Icons.map, Icons.settings];

  @override
  void initState() {
    super.initState();
    _telSub  = widget.ble.telemetryStream.listen((t) => setState(() => _tel = t));
    _connSub = widget.ble.connectionStream.listen(_onConnectionChange);
  }

  void _onConnectionChange(bool connected) {
    if (!connected && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('BLE desconectado')),
      );
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const ScanScreen()),
      );
    }
  }

  Future<void> _disconnect() async {
    await widget.ble.disconnect();
  }

  @override
  void dispose() {
    _telSub?.cancel();
    _connSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      RemoteScreen(ble: widget.ble, tel: _tel),
      MapScreen(ble: widget.ble, tel: _tel),
      SettingsScreen(ble: widget.ble),
    ];

    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1B2A3B),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.anchor, color: Colors.blue.shade300, size: 20),
            const SizedBox(width: 8),
            const Text('Módulo Barco', style: TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.bluetooth_disabled, color: Colors.white70),
            tooltip: 'Desconectar',
            onPressed: _disconnect,
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
                        color: _selectedIndex == i
                            ? Colors.blue.shade400
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _tabIcons[i],
                        color: _selectedIndex == i
                            ? Colors.blue.shade400
                            : Colors.white38,
                        size: 20,
                      ),
                      Text(
                        _tabLabels[i],
                        style: TextStyle(
                          color: _selectedIndex == i
                              ? Colors.blue.shade400
                              : Colors.white38,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )),
          ),
        ),
      ),
      body: IndexedStack(
        index: _selectedIndex,
        children: screens,
      ),
    );
  }
}
