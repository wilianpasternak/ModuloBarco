import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/ble_service.dart';
import 'app_shell.dart';

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final List<ScanResult> _results = [];
  bool _scanning = false;
  StreamSubscription? _scanSub;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
  }

  String? _bleError;

  Future<void> _requestPermissions() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
  }

  String _deviceName(ScanResult r) {
    if (r.device.platformName.isNotEmpty) return r.device.platformName;
    if (r.advertisementData.advName.isNotEmpty) return r.advertisementData.advName;
    return 'Desconhecido';
  }

  Future<void> _startScan() async {
    setState(() { _bleError = null; _results.clear(); _scanning = true; });

    // Verifica estado do Bluetooth antes de escanear
    final btState = await FlutterBluePlus.adapterState.first;
    if (btState != BluetoothAdapterState.on) {
      setState(() {
        _scanning = false;
        _bleError = 'Bluetooth desligado ou permissão negada.\n\n'
            'iOS: Ajustes > Privacidade e Segurança > Bluetooth\n'
            'e ative para "Barco App"';
      });
      return;
    }

    // Sem filtro withServices — iOS às vezes coloca o UUID no scan response
    // e nesse caso withServices bloqueia o dispositivo. Mostra todos os
    // dispositivos BLE para o usuario escolher o ModuloBarco.
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));

    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      setState(() {
        for (final r in results) {
          if (!_results.any((e) => e.device.remoteId == r.device.remoteId)) {
            _results.add(r);
          }
        }
        // Ordena: ModuloBarco primeiro
        _results.sort((a, b) {
          final aIsTarget = _deviceName(a) == 'ModuloBarco' ? 0 : 1;
          final bIsTarget = _deviceName(b) == 'ModuloBarco' ? 0 : 1;
          return aIsTarget.compareTo(bIsTarget);
        });
      });
    });

    await Future.delayed(const Duration(seconds: 10));
    await FlutterBluePlus.stopScan();
    setState(() => _scanning = false);
  }

  Future<void> _connect(BluetoothDevice device) async {
    final ble = BleService();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(children: [
          CircularProgressIndicator(),
          SizedBox(width: 16),
          Text('Conectando...'),
        ]),
      ),
    );
    try {
      await ble.connect(device);
      if (!mounted) return;
      Navigator.of(context).pop();
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => AppShell(ble: ble)),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erro ao conectar: $e')),
      );
    }
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1B2A3B),
        title: const Text('Módulo Barco', style: TextStyle(color: Colors.white)),
        centerTitle: true,
      ),
      body: Column(
        children: [
          const SizedBox(height: 24),
          Icon(Icons.bluetooth_searching, size: 64, color: Colors.blue.shade300),
          const SizedBox(height: 12),
          const Text('Procurando ModuloBarco...', style: TextStyle(color: Colors.white70, fontSize: 16)),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _scanning ? null : _startScan,
            icon: _scanning
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.search),
            label: Text(_scanning ? 'Procurando...' : 'Iniciar varredura'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue.shade700,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
            ),
          ),
          const SizedBox(height: 24),
          if (_bleError != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.red.shade900.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.red.shade700),
                ),
                child: Text(_bleError!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70, fontSize: 13)),
              ),
            ),
          Expanded(
            child: _results.isEmpty
                ? Center(
                    child: Text(
                      _scanning ? '' : 'Nenhum dispositivo encontrado',
                      style: const TextStyle(color: Colors.white38),
                    ),
                  )
                : ListView.builder(
                    itemCount: _results.length,
                    itemBuilder: (_, i) {
                      final r = _results[i];
                      final name = _deviceName(r);
                      final isTarget = name == 'ModuloBarco';
                      return Card(
                        color: isTarget
                            ? const Color(0xFF1A2A10)
                            : const Color(0xFF1B2A3B),
                        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: BorderSide(
                            color: isTarget ? Colors.green.shade600 : Colors.transparent,
                            width: 1.5,
                          ),
                        ),
                        child: ListTile(
                          leading: Icon(Icons.bluetooth,
                              color: isTarget ? Colors.green.shade400 : Colors.blue),
                          title: Text(name,
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: isTarget ? FontWeight.bold : FontWeight.normal,
                              )),
                          subtitle: Text(r.device.remoteId.toString(),
                              style: const TextStyle(color: Colors.white38, fontSize: 12)),
                          trailing: Text('${r.rssi} dBm',
                              style: const TextStyle(color: Colors.white54, fontSize: 12)),
                          onTap: () => _connect(r.device),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
