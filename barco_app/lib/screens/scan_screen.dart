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
  bool _scanDone = false;
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
    return '';
  }

  Future<void> _startScan() async {
    setState(() { _bleError = null; _results.clear(); _scanning = true; _scanDone = false; });

    // Aguarda estado estável do adaptador (iOS pode retornar 'unknown' transitoriamente)
    final btState = await FlutterBluePlus.adapterState
        .where((s) => s != BluetoothAdapterState.unknown)
        .first
        .timeout(const Duration(seconds: 3),
            onTimeout: () => BluetoothAdapterState.unknown);

    if (btState != BluetoothAdapterState.on) {
      setState(() {
        _scanning = false;
        _bleError = 'Bluetooth desligado ou permissão negada.\n\n'
            'iOS: Ajustes > Privacidade e Segurança > Bluetooth\n'
            'e ative para "Pesca Plus"';
      });
      return;
    }

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));

    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      setState(() {
        for (final r in results) {
          if (_deviceName(r) != 'BragaPesca') continue;
          if (!_results.any((e) => e.device.remoteId == r.device.remoteId)) {
            _results.add(r);
          }
        }
      });
    });

    await Future.delayed(const Duration(seconds: 10));
    await FlutterBluePlus.stopScan();
    setState(() { _scanning = false; _scanDone = true; });
  }

  void _continueOffline() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => AppShell(ble: BleService(), startOffline: true),
      ),
    );
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
          Text('Conectando ao motor...',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.8))),
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
    final emptyMessage = _scanDone
        ? 'Motor não encontrado.\nVerifique se o motor está ligado e próximo.'
        : '';

    return Scaffold(
      backgroundColor: _kDark,
      bottomNavigationBar: (_scanDone && _results.isEmpty)
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                child: OutlinedButton(
                  onPressed: _continueOffline,
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: _kGoldDim),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(30)),
                  ),
                  child: const Text('Continuar sem conectar',
                      style: TextStyle(color: _kGoldDim)),
                ),
              ),
            )
          : null,
      appBar: AppBar(
        backgroundColor: _kPanel,
        title: const Text('Pesca Plus',
            style: TextStyle(color: _kGold, fontWeight: FontWeight.bold, letterSpacing: 1)),
        centerTitle: true,
      ),
      body: Column(
        children: [
          const SizedBox(height: 32),
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
                      emptyMessage,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: _kGoldDim, height: 1.6),
                    ),
                  )
                : ListView.builder(
                    itemCount: _results.length,
                    itemBuilder: (_, i) {
                      final r = _results[i];
                      return Card(
                        color: const Color(0xFF1A2A10),
                        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: const BorderSide(color: _kGold, width: 1.5),
                        ),
                        child: ListTile(
                          leading: const Icon(Icons.bluetooth, color: _kGold),
                          title: const Text('Pesca Plus',
                              style: TextStyle(color: Colors.white,
                                  fontWeight: FontWeight.bold)),
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
