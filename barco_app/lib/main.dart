import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/scan_screen.dart';

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
      title: 'Módulo Barco',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0D1B2A),
        colorScheme: ColorScheme.dark(
          primary: Colors.blue.shade400,
          surface: const Color(0xFF1B2A3B),
        ),
      ),
      home: const ScanScreen(),
    );
  }
}
