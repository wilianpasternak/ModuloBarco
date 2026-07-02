import 'dart:async';
import 'package:flutter/material.dart';
import '../services/ble_service.dart';
import 'scan_screen.dart';

const _kGold    = Color(0xFFD4A800);
const _kGoldDim = Color(0xFF6B5400);
const _kPanel   = Color(0xFF1A1A10);
const _kDark    = Color(0xFF0F0F08);

class SettingsScreen extends StatefulWidget {
  final BleService ble;
  final int initialPwmHelMin;
  const SettingsScreen({super.key, required this.ble, this.initialPwmHelMin = 0});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int _pwmHelMin = 0;
  StreamSubscription? _hmnSub;

  // OTA state
  String? _latestVersion;
  String? _otaUrl;
  double? _otaProgress;

  @override
  void initState() {
    super.initState();
    _pwmHelMin = widget.initialPwmHelMin;
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
        backgroundColor: _kPanel,
        title: const Text('Calibrar Bússola', style: TextStyle(color: _kGold)),
        content: const Text(
          'O motor vai girar 360° para cada lado durante ~20 segundos.\n\nCertifique-se de que o barco esteja na água e com espaço livre.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar', style: TextStyle(color: _kGoldDim)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: _kGold),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Iniciar', style: TextStyle(color: _kDark)),
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

  Future<void> _checkForUpdate() async {
    final result = await widget.ble.checkForUpdate();
    if (!mounted) return;
    if (result == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Erro de rede. Verifique sua conexão.')));
      return;
    }
    if (result['version'] == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nenhuma atualização disponível ainda.')));
      return;
    }
    setState(() {
      _latestVersion = result['version'] as String;
      _otaUrl = result['url'] as String;
    });
    if (_latestVersion == widget.ble.firmwareVersion) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Você já está na versão mais recente (v$_latestVersion).')));
    }
  }

  Future<void> _startOta() async {
    if (_otaUrl == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _kPanel,
        title: const Text('Atualizar firmware?', style: TextStyle(color: _kGold)),
        content: Text(
          'O motor será atualizado para v$_latestVersion.\n\nMantenha o motor parado e o celular próximo durante a atualização (~2 min).',
          style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar', style: TextStyle(color: _kGoldDim))),
          TextButton(onPressed: () => Navigator.pop(context, true),
              child: const Text('Atualizar', style: TextStyle(color: _kGold))),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _otaProgress = 0.0);
    final ok = await widget.ble.performOta(_otaUrl!, (p) {
      if (mounted) setState(() => _otaProgress = p);
    });
    setState(() => _otaProgress = null);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? 'Firmware atualizado! O motor está reiniciando...'
            : 'Falha na atualização. Tente novamente.'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle('Motor'),
          const SizedBox(height: 12),

          // ── PWM Mínimo da Hélice ─────────────────────────────────
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _kPanel,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _kGoldDim.withValues(alpha: 0.5)),
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
                  valueColor: const AlwaysStoppedAnimation<Color>(_kGold),
                  borderRadius: BorderRadius.circular(4),
                  minHeight: 6,
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),

          // ── Calibracao bussola ───────────────────────────────────
          _SectionTitle('Bússola'),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _kPanel,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _kGoldDim.withValues(alpha: 0.5)),
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
                      backgroundColor: _kGoldDim,
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

          // ── Procurar novo motor ──────────────────────────────────
          const SizedBox(height: 24),
          GestureDetector(
            onTap: () async {
              await widget.ble.disconnect();
              await BleService.clearSavedDevice();
              if (context.mounted) {
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const ScanScreen()),
                  (route) => false,
                );
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _kGoldDim, width: 1.5),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.bluetooth_searching, color: _kGoldDim, size: 20),
                  SizedBox(width: 8),
                  Text('Procurar novo motor',
                      style: TextStyle(color: _kGoldDim, fontSize: 14, fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          ),

          // ── Atualização de Firmware (OTA) ────────────────────────
          const SizedBox(height: 30),
          _SectionTitle('ATUALIZAÇÃO DE FIRMWARE'),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Versão atual: ${widget.ble.firmwareVersion}',
                  style: const TextStyle(color: _kGoldDim, fontSize: 13)),
              if (_latestVersion != null)
                Text('Versão disponível: $_latestVersion',
                    style: const TextStyle(color: _kGold, fontSize: 13)),
            ])),
          ]),
          const SizedBox(height: 12),
          if (_otaProgress != null)
            Column(children: [
              LinearProgressIndicator(value: _otaProgress, color: _kGold,
                  backgroundColor: _kGoldDim.withValues(alpha: 0.3)),
              const SizedBox(height: 8),
              Text('${((_otaProgress ?? 0) * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(color: _kGold, fontSize: 13)),
            ])
          else
            Row(children: [
              Expanded(child: _GoldOutlineBtn(
                label: 'Verificar atualização',
                icon: Icons.cloud_download_outlined,
                onTap: _checkForUpdate,
              )),
              if (_latestVersion != null && _latestVersion != widget.ble.firmwareVersion) ...[
                const SizedBox(width: 10),
                Expanded(child: _GoldOutlineBtn(
                  label: 'Atualizar',
                  icon: Icons.system_update_alt,
                  onTap: _startOta,
                  gold: true,
                )),
              ],
            ]),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

// ── Section title (gold divider style) ──────────────────────────────────────
class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) => Row(children: [
    Expanded(child: Divider(color: _kGoldDim.withValues(alpha: 0.4))),
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Text(text.toUpperCase(),
          style: const TextStyle(color: _kGoldDim, fontSize: 10, letterSpacing: 2)),
    ),
    Expanded(child: Divider(color: _kGoldDim.withValues(alpha: 0.4))),
  ]);
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
          color: onPressed != null ? _kGold : Colors.grey.shade800,
        ),
        child: Center(
          child: Text(label,
              style: TextStyle(
                color: onPressed != null ? _kDark : Colors.white38,
                fontSize: 26,
                fontWeight: FontWeight.bold,
              )),
        ),
      ),
    );
  }
}

// ── Gold outline button ───────────────────────────────────────────────────────
class _GoldOutlineBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool gold;
  const _GoldOutlineBtn({required this.label, required this.icon, required this.onTap, this.gold = false});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: gold ? _kGold : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: gold ? _kGold : _kGoldDim, width: 1.5),
      ),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, color: gold ? _kDark : _kGoldDim, size: 18),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(
          color: gold ? _kDark : _kGoldDim,
          fontSize: 12, fontWeight: FontWeight.w600,
        )),
      ]),
    ),
  );
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
      backgroundColor: _kPanel,
      title: const Text('Calibrando Bússola', style: TextStyle(color: _kGold)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(phase, style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 16),
          LinearProgressIndicator(
            value: progress,
            backgroundColor: Colors.white12,
            valueColor: const AlwaysStoppedAnimation<Color>(_kGold),
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
