import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/scan_screen.dart';
import 'screens/app_shell.dart';
import 'services/ble_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const BarcoApp());
}

class BarcoApp extends StatelessWidget {
  const BarcoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Braga Pesca',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F0F08),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFD4A800),
          surface: Color(0xFF1A1A10),
        ),
      ),
      home: const _StartupScreen(),
    );
  }
}

class _StartupScreen extends StatefulWidget {
  const _StartupScreen();
  @override
  State<_StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<_StartupScreen> {
  @override
  void initState() {
    super.initState();
    _checkSavedDevice();
  }

  Future<void> _checkSavedDevice() async {
    final savedId = await BleService.getSavedDeviceId();
    if (!mounted) return;
    if (savedId != null) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => AppShell(ble: BleService(), autoReconnect: true),
        ),
      );
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const ScanScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF0F0F08),
      body: Center(
        child: CircularProgressIndicator(color: Color(0xFFD4A800)),
      ),
    );
  }
}
