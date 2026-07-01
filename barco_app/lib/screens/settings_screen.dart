import 'dart:async';
import 'package:flutter/material.dart';
import '../services/ble_service.dart';

class SettingsScreen extends StatefulWidget {
  final BleService ble;
  const SettingsScreen({super.key, required this.ble});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int _pwmHelMin = 0;
  StreamSubscription? _hmnSub;

  @override
  void initState() {
    super.initState();
    _hmnSub = widget.ble.pwmHelMinStream.listen((v) => setState(() => _pwmHelMin = v));
  }

  @override
  void dispose() {
    _hmnSub?.cancel();
    super.dispose();
  }

  Future<void> _incrementPwm() async {
    await widget.ble.sendPwmHelMinPlus();
  }

  Future<void> _decrementPwm() async {
    await widget.ble.sendPwmHelMinMinus();
  }

  Future<void> _calibrate() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1B2A3B),
        title: const Text('Calibrar Bússola', style: TextStyle(color: Colors.white)),
        content: const Text(
          'O motor vai girar 360° para cada lado durante ~20 segundos.\n\nCertifique-se de que o barco esteja na água e com espaço livre.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue.shade700),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Iniciar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // Envia comando e mostra progresso por 22 segundos
    await widget.ble.sendCalibrate();
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _CalibrationProgressDialog(),
    );

    await Future.delayed(const Duration(seconds: 22));
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle('Motor'),
          const SizedBox(height: 12),

          // ── PWM Mínimo da Hélice ─────────────────────────────────
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1B2A3B),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('PWM Mínimo da Hélice',
                    style: TextStyle(color: Colors.white70, fontSize: 13)),
                const SizedBox(height: 4),
                const Text(
                  'Valor mínimo de PWM para o motor sair da inércia na água. '
                  'Pressione + ou – com o barco na água até o motor começar a girar.',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _PwmBtn(
                      label: '–',
                      onPressed: _pwmHelMin > 0 ? _decrementPwm : null,
                    ),
                    const SizedBox(width: 24),
                    Column(
                      children: [
                        Text(
                          '$_pwmHelMin',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 40,
                            fontWeight: FontWeight.bold,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                        const Text('/ 255', style: TextStyle(color: Colors.white38, fontSize: 12)),
                      ],
                    ),
                    const SizedBox(width: 24),
                    _PwmBtn(
                      label: '+',
                      onPressed: _pwmHelMin < 255 ? _incrementPwm : null,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: _pwmHelMin / 255.0,
                  backgroundColor: Colors.white12,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.blue.shade400),
                  borderRadius: BorderRadius.circular(4),
                  minHeight: 6,
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),

          // ── Calibracao bussola ───────────────────────────────────
          const _SectionTitle('Bússola'),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1B2A3B),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Calibração de Campo',
                    style: TextStyle(color: Colors.white70, fontSize: 13)),
                const SizedBox(height: 4),
                const Text(
                  'Realiza a calibração do magnetômetro HMC5883L. '
                  'O motor girará 360° para cada lado. Execute com o barco na água.',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.teal.shade800,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: const Icon(Icons.explore),
                    label: const Text('Calibrar Bússola', style: TextStyle(fontSize: 15)),
                    onPressed: _calibrate,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Section title ────────────────────────────────────────────────────────────
class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: TextStyle(
      color: Colors.blue.shade300,
      fontSize: 11,
      fontWeight: FontWeight.bold,
      letterSpacing: 1.8,
    ),
  );
}

// ── PWM +/- button ────────────────────────────────────────────────────────────
class _PwmBtn extends StatelessWidget {
  final String label;
  final Future<void> Function()? onPressed;
  const _PwmBtn({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: onPressed != null ? Colors.blue.shade700 : Colors.grey.shade800,
        ),
        child: Center(
          child: Text(label,
              style: TextStyle(
                color: onPressed != null ? Colors.white : Colors.white38,
                fontSize: 26,
                fontWeight: FontWeight.bold,
              )),
        ),
      ),
    );
  }
}

// ── Calibration progress dialog ───────────────────────────────────────────────
class _CalibrationProgressDialog extends StatefulWidget {
  const _CalibrationProgressDialog();

  @override
  State<_CalibrationProgressDialog> createState() => _CalibrationProgressDialogState();
}

class _CalibrationProgressDialogState extends State<_CalibrationProgressDialog> {
  int _elapsed = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed++);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = (_elapsed / 22.0).clamp(0.0, 1.0);
    final phase = _elapsed < 11 ? 'Girando esquerda...' : 'Girando direita...';
    return AlertDialog(
      backgroundColor: const Color(0xFF1B2A3B),
      title: const Text('Calibrando Bússola', style: TextStyle(color: Colors.white)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(phase, style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 16),
          LinearProgressIndicator(
            value: progress,
            backgroundColor: Colors.white12,
            valueColor: AlwaysStoppedAnimation<Color>(Colors.teal.shade400),
            minHeight: 8,
            borderRadius: BorderRadius.circular(4),
          ),
          const SizedBox(height: 8),
          Text('${_elapsed}s / 22s', style: const TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      ),
    );
  }
}
