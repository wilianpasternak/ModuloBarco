import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/ble_service.dart';
import 'app_shell.dart';

const _kGold    = Color(0xFFD4A800);
const _kGoldDim = Color(0xFF6B5400);
const _kDark    = Color(0xFF0F0F08);
const _kPanel   = Color(0xFF1A1A10);

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});
  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final List<ScanResult> _results = [];
  bool _scanning = false;
  StreamSubscription? _scanSub;
  String? _bleError;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
  }

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

    final btState = await FlutterBluePlus.adapterState.first;
    if (btState != BluetoothAdapterState.on) {
      setState(() {
        _scanning = false;
        _bleError = 'Bluetooth desligado ou permissão negada.\n\n'
            'iOS: Ajustes > Privacidade e Segurança > Bluetooth\n'
            'e ative para "Braga Pesca"';
      });
      return;
    }

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));

    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      setState(() {
        for (final r in results) {
          if (!_results.any((e) => e.device.remoteId == r.device.remoteId)) {
            _results.add(r);
          }
        }
        _results.sort((a, b) {
          final aT = _deviceName(a) == 'BragaPesca' ? 0 : 1;
          final bT = _deviceName(b) == 'BragaPesca' ? 0 : 1;
          return aT.compareTo(bT);
        });
      });
    });

    await Future.delayed(const Duration(seconds: 10));
    await FlutterBluePlus.stopScan();
    setState(() => _scanning = false);
  }

  Future<void> _connect(BluetoothDevice device) async {
    final ble = BleService();
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: _kPanel,
        content: Row(children: [
          const CircularProgressIndicator(color: _kGold),
          const SizedBox(width: 16),
          Text('Conectando ao motor...', style: TextStyle(color: Colors.white.withValues(alpha: 0.8))),
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
      backgroundColor: _kDark,
      appBar: AppBar(
        backgroundColor: _kPanel,
        title: const Text('Braga Pesca',
            style: TextStyle(color: _kGold, fontWeight: FontWeight.bold, letterSpacing: 1)),
        centerTitle: true,
      ),
      body: Column(
        children: [
          const SizedBox(height: 32),
          // Logo
          Image.asset('assets/logo_braga_pesca.png', height: 110),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _scanning ? null : _startScan,
            icon: _scanning
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: _kDark))
                : const Icon(Icons.search, color: _kDark),
            label: Text(_scanning ? 'Procurando...' : 'Procurar Motor',
                style: const TextStyle(color: _kDark, fontWeight: FontWeight.bold)),
            style: ElevatedButton.styleFrom(
              backgroundColor: _kGold,
              disabledBackgroundColor: _kGoldDim,
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
            ),
          ),
          const SizedBox(height: 20),
          if (_bleError != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.red.shade900.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.red.shade700),
                ),
                child: Text(_bleError!, textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70, fontSize: 13)),
              ),
            ),
          Expanded(
            child: _results.isEmpty
                ? Center(
                    child: Text(
                      _scanning ? '' : 'Nenhum dispositivo encontrado',
                      style: const TextStyle(color: _kGoldDim),
                    ),
                  )
                : ListView.builder(
                    itemCount: _results.length,
                    itemBuilder: (_, i) {
                      final r = _results[i];
                      final name = _deviceName(r);
                      final isTarget = name == 'BragaPesca';
                      return Card(
                        color: isTarget ? const Color(0xFF1A2A10) : _kPanel,
                        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: BorderSide(
                            color: isTarget ? _kGold : Colors.transparent, width: 1.5),
                        ),
                        child: ListTile(
                          leading: Icon(Icons.bluetooth,
                              color: isTarget ? _kGold : Colors.blue.shade300),
                          title: Text(name, style: TextStyle(
                            color: Colors.white,
                            fontWeight: isTarget ? FontWeight.bold : FontWeight.normal,
                          )),
                          subtitle: Text(r.device.remoteId.toString(),
                              style: const TextStyle(color: _kGoldDim, fontSize: 11)),
                          trailing: Text('${r.rssi} dBm',
                              style: const TextStyle(color: _kGoldDim, fontSize: 12)),
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
