import 'dart:async';
import 'package:flutter/material.dart';
import '../services/ble_service.dart';
import '../models/telemetry.dart';

// Paleta dourada — espelha o controle físico Braga Pesca
const _kGold    = Color(0xFFD4A800);
const _kGoldDim = Color(0xFF6B5400);
const _kPanel   = Color(0xFF1A1A10);
const _kDark    = Color(0xFF0F0F08);

class RemoteScreen extends StatefulWidget {
  final BleService ble;
  final Telemetry? tel;
  const RemoteScreen({super.key, required this.ble, this.tel});

  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen> {
  Timer? _acelTimer;
  Timer? _giroTimer;
  Timer? _upDownTimer;

  bool _verificarBLE() {
    if (widget.ble.isConnected) return true;
    if (!mounted) return false;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text('Sem conexão com o motor.',
          style: TextStyle(color: Colors.white)),
      backgroundColor: Colors.red.withValues(alpha: 0.85),
      duration: const Duration(seconds: 3),
    ));
    return false;
  }

  bool _verificarNorteInativo() {
    if (!(widget.tel?.northActive ?? false)) return true;
    if (!mounted) return false;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _kPanel,
        title: const Row(children: [
          Icon(Icons.navigation, color: _kGold, size: 22),
          SizedBox(width: 8),
          Text('Modo Norte Ativo', style: TextStyle(color: _kGold)),
        ]),
        content: const Text(
          'O modo de apontamento para o norte está ativo.\n\n'
          'Desative-o antes de controlar o motor.',
          style: TextStyle(color: Colors.white70, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar', style: TextStyle(color: _kGoldDim)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: _kGold),
            onPressed: () {
              Navigator.pop(context);
              _toggleNorth();
            },
            child: const Text('Desativar Norte', style: TextStyle(color: _kDark)),
          ),
        ],
      ),
    );
    return false;
  }

  // ── Acelerador hold ──────────────────────────────────────────────
  void _startAcel(bool plus) {
    if (!_verificarBLE()) return;
    if (!_verificarNorteInativo()) return;
    _sendAcelOnce(plus);
    _acelTimer = Timer.periodic(const Duration(milliseconds: 120), (_) => _sendAcelOnce(plus));
  }

  void _stopAcel() { _acelTimer?.cancel(); _acelTimer = null; }

  void _sendAcelOnce(bool plus) async {
    // Se motor desligado e usuario acelerou, ligar o motor primeiro
    final tel = widget.tel;
    if (tel != null && !tel.motorLigado) {
      await widget.ble.sendToggleMotor();
      await Future.delayed(const Duration(milliseconds: 50));
    }
    if (plus) { widget.ble.sendAcelPlus(); } else { widget.ble.sendAcelMinus(); }
  }

  // ── Giro hold (reenvia 100ms; envia stop explicito ao soltar) ───
  Future<void> Function()? _giroStop;

  void _startGiro(bool right) {
    if (!_verificarBLE()) return;
    if (!_verificarNorteInativo()) return;
    _giroTimer?.cancel();
    final send = right ? widget.ble.sendGiroDirStart : widget.ble.sendGiroEsqStart;
    _giroStop = right ? widget.ble.sendGiroDirStop : widget.ble.sendGiroEsqStop;
    send();
    _giroTimer = Timer.periodic(const Duration(milliseconds: 100), (_) => send());
  }

  void _stopGiro() {
    _giroTimer?.cancel();
    _giroTimer = null;
    _giroStop?.call();
    _giroStop = null;
  }

  Future<void> _toggleMotor() async {
    if (!_verificarBLE()) return;
    if (!_verificarNorteInativo()) return;
    await widget.ble.sendToggleMotor();
  }

  Future<void> _toggleNorth() async {
    if (!_verificarBLE()) return;
    await widget.ble.sendToggleNorth();
  }

  Future<void> _startUpChecked() async {
    if (!_verificarBLE()) return;
    if (!_verificarNorteInativo()) return;
    _upDownTimer?.cancel();
    widget.ble.sendUpStart();
    _upDownTimer = Timer.periodic(const Duration(milliseconds: 100), (_) => widget.ble.sendUpStart());
  }

  Future<void> _stopUp() async {
    _upDownTimer?.cancel();
    _upDownTimer = null;
    await widget.ble.sendUpStop();
  }

  Future<void> _startDownChecked() async {
    if (!_verificarBLE()) return;
    if (!_verificarNorteInativo()) return;
    _upDownTimer?.cancel();
    widget.ble.sendDownStart();
    _upDownTimer = Timer.periodic(const Duration(milliseconds: 100), (_) => widget.ble.sendDownStart());
  }

  Future<void> _stopDown() async {
    _upDownTimer?.cancel();
    _upDownTimer = null;
    await widget.ble.sendDownStop();
  }

  Future<void> _toggleAnchor() async {
    if (!_verificarBLE()) return;
    final tel = widget.tel;
    final jaAtiva = tel?.anchorActive ?? false;
    // Se tentando ATIVAR e GPS sem fix → bloqueia com alerta
    if (!jaAtiva && !(tel?.gpsFix ?? false)) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: _kPanel,
          title: Row(children: [
            Icon(Icons.gps_not_fixed, color: Colors.red.shade400, size: 22),
            const SizedBox(width: 8),
            const Text('GPS sem sinal', style: TextStyle(color: _kGold)),
          ]),
          content: const Text(
            'O GPS ainda não está com sinal fixo.\n\n'
            'Aguarde o card GPS mostrar "OK" (verde) antes de ativar a âncora.',
            style: TextStyle(color: Colors.white70, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Entendido', style: TextStyle(color: _kGold)),
            ),
          ],
        ),
      );
      return;
    }
    await widget.ble.sendToggleAnchor();
  }

  @override
  void dispose() {
    _acelTimer?.cancel();
    _giroTimer?.cancel();
    _upDownTimer?.cancel();
    _giroStop = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tel = widget.tel;
    final anchorActive = tel?.anchorActive ?? false;
    final northActive  = tel?.northActive  ?? false;
    final motorActive  = tel?.motorLigado  ?? false;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Column(
        children: [
          // ── Telemetria ───────────────────────────────────────────
          _StatusBar(tel: tel),
          const SizedBox(height: 20),

          // ══════════════════════════════════════════════════════════
          // PAINEL SUPERIOR  —  Acelerador + Giro + Motor
          // ══════════════════════════════════════════════════════════
          _GoldPanel(
            verticalPadding: 28,
            child: Column(
              children: [
                // + (Acelerar) — pill
                _PillHoldBtn(
                  label: '+',
                  onStart: () => _startAcel(true),
                  onStop:  _stopAcel,
                ),
                const SizedBox(height: 24),

                // ◄  Motor  ►
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _ArrowHoldBtn(
                      icon: Icons.arrow_back_ios_rounded,
                      onStart: () => _startGiro(false),
                      onStop:  _stopGiro,
                    ),
                    _MotorCircleBtn(
                      active: motorActive,
                      onTap: _toggleMotor,
                    ),
                    _ArrowHoldBtn(
                      icon: Icons.arrow_forward_ios_rounded,
                      onStart: () => _startGiro(true),
                      onStop:  _stopGiro,
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                // - (Desacelerar) — pill
                _PillHoldBtn(
                  label: '–',
                  onStart: () => _startAcel(false),
                  onStop:  _stopAcel,
                ),
              ],
            ),
          ),

          const SizedBox(height: 32),

          // ══════════════════════════════════════════════════════════
          // PAINEL INFERIOR  —  Ancora + Norte + Subir + Descer
          // ══════════════════════════════════════════════════════════
          _GoldPanel(
            verticalPadding: 14,
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _CircleToggleBtn(
                      icon: Icons.anchor,
                      label: 'ÂNCORA',
                      active: anchorActive,
                      onTap: _toggleAnchor,
                      size: 58,
                      iconSize: 26,
                    ),
                    _CircleToggleBtn(
                      icon: Icons.gps_fixed,
                      label: 'NORTE',
                      active: northActive,
                      onTap: _toggleNorth,
                      size: 58,
                      iconSize: 26,
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _CircleHoldBtn(
                      icon: Icons.keyboard_arrow_up_rounded,
                      label: 'SUBIR',
                      onStart: _startUpChecked,
                      onStop:  _stopUp,
                      size: 58,
                      iconSize: 30,
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Text('MÓDULO', style: TextStyle(
                          color: _kGoldDim, fontSize: 9, letterSpacing: 2,
                          fontWeight: FontWeight.bold,
                        )),
                        Text('BARCO', style: TextStyle(
                          color: _kGold, fontSize: 12, letterSpacing: 3,
                          fontWeight: FontWeight.bold,
                        )),
                      ],
                    ),
                    _CircleHoldBtn(
                      icon: Icons.keyboard_arrow_down_rounded,
                      label: 'DESCER',
                      onStart: _startDownChecked,
                      onStop:  _stopDown,
                      size: 58,
                      iconSize: 30,
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

// ── Painel com borda dourada arredondada ─────────────────────────────────────
class _GoldPanel extends StatelessWidget {
  final Widget child;
  final double verticalPadding;
  const _GoldPanel({required this.child, this.verticalPadding = 22});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(horizontal: 28, vertical: verticalPadding),
      decoration: BoxDecoration(
        color: _kPanel,
        borderRadius: BorderRadius.circular(60),
        border: Border.all(color: _kGold, width: 2.5),
        boxShadow: [
          BoxShadow(color: _kGold.withValues(alpha: 0.12), blurRadius: 20, spreadRadius: 1),
        ],
      ),
      child: child,
    );
  }
}

// ── Pill hold button ( + / - ) ───────────────────────────────────────────────
class _PillHoldBtn extends StatefulWidget {
  final String label;
  final VoidCallback onStart;
  final VoidCallback onStop;
  const _PillHoldBtn({required this.label, required this.onStart, required this.onStop});

  @override
  State<_PillHoldBtn> createState() => _PillHoldBtnState();
}

class _PillHoldBtnState extends State<_PillHoldBtn> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown:   (_) { setState(() => _pressed = true);  widget.onStart(); },
      onPointerUp:     (_) { setState(() => _pressed = false); widget.onStop();  },
      onPointerCancel: (_) { setState(() => _pressed = false); widget.onStop();  },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        height: 52,
        decoration: BoxDecoration(
          color: _pressed ? _kGold : Colors.transparent,
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: _pressed ? _kGold : _kGoldDim, width: 2),
        ),
        child: Center(
          child: Text(
            widget.label,
            style: TextStyle(
              color: _pressed ? _kDark : _kGold,
              fontSize: 28,
              fontWeight: FontWeight.bold,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

// ── Arrow hold button ( ◄ / ► ) ─────────────────────────────────────────────
class _ArrowHoldBtn extends StatefulWidget {
  final IconData icon;
  final VoidCallback onStart;
  final VoidCallback onStop;
  const _ArrowHoldBtn({required this.icon, required this.onStart, required this.onStop});

  @override
  State<_ArrowHoldBtn> createState() => _ArrowHoldBtnState();
}

class _ArrowHoldBtnState extends State<_ArrowHoldBtn> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown:   (_) { setState(() => _pressed = true);  widget.onStart(); },
      onPointerUp:     (_) { setState(() => _pressed = false); widget.onStop();  },
      onPointerCancel: (_) { setState(() => _pressed = false); widget.onStop();  },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        width: 84, height: 84,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _pressed ? _kGold : Colors.transparent,
          border: Border.all(color: _pressed ? _kGold : _kGoldDim, width: 2),
        ),
        child: Icon(widget.icon,
          color: _pressed ? _kDark : _kGold,
          size: 38,
        ),
      ),
    );
  }
}

// ── Motor circle button (centro) ─────────────────────────────────────────────
class _MotorCircleBtn extends StatefulWidget {
  final bool active;
  final Future<void> Function() onTap;
  const _MotorCircleBtn({required this.active, required this.onTap});

  @override
  State<_MotorCircleBtn> createState() => _MotorCircleBtnState();
}

class _MotorCircleBtnState extends State<_MotorCircleBtn> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.active;
    return GestureDetector(
      onTapDown:   (_) => setState(() => _pressed = true),
      onTapUp:     (_) { setState(() => _pressed = false); widget.onTap(); },
      onTapCancel: ()  => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 78, height: 78,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active ? _kGold : (_pressed ? _kGoldDim : Colors.transparent),
          border: Border.all(color: _kGold, width: 2.5),
          boxShadow: active
              ? [BoxShadow(color: _kGold.withValues(alpha: 0.45), blurRadius: 18)]
              : null,
        ),
        child: Icon(Icons.wind_power,
          color: active ? _kDark : _kGold,
          size: 38,
        ),
      ),
    );
  }
}

// ── Circle toggle button ( ⚓ / ⊕ ) ─────────────────────────────────────────
class _CircleToggleBtn extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool active;
  final Future<void> Function() onTap;
  final double size;
  final double iconSize;
  const _CircleToggleBtn({
    required this.icon, required this.label,
    required this.active, required this.onTap,
    this.size = 72, this.iconSize = 34,
  });

  @override
  State<_CircleToggleBtn> createState() => _CircleToggleBtnState();
}

class _CircleToggleBtnState extends State<_CircleToggleBtn> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.active;
    return GestureDetector(
      onTapDown:   (_) => setState(() => _pressed = true),
      onTapUp:     (_) { setState(() => _pressed = false); widget.onTap(); },
      onTapCancel: ()  => setState(() => _pressed = false),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: widget.size, height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? _kGold : (_pressed ? _kGoldDim : Colors.transparent),
              border: Border.all(color: active ? _kGold : _kGoldDim, width: 2.5),
              boxShadow: active
                  ? [BoxShadow(color: _kGold.withValues(alpha: 0.45), blurRadius: 14)]
                  : null,
            ),
            child: Icon(widget.icon,
              color: active ? _kDark : _kGold,
              size: widget.iconSize,
            ),
          ),
          const SizedBox(height: 5),
          Text(widget.label, style: TextStyle(
            color: active ? _kGold : _kGoldDim,
            fontSize: 9,
            letterSpacing: 1.5,
            fontWeight: FontWeight.bold,
          )),
        ],
      ),
    );
  }
}

// ── Circle hold button ( ↑ / ↓ ) ─────────────────────────────────────────────
class _CircleHoldBtn extends StatefulWidget {
  final IconData icon;
  final String label;
  final Future<void> Function() onStart;
  final Future<void> Function() onStop;
  final double size;
  final double iconSize;
  const _CircleHoldBtn({
    required this.icon, required this.label,
    required this.onStart, required this.onStop,
    this.size = 72, this.iconSize = 38,
  });

  @override
  State<_CircleHoldBtn> createState() => _CircleHoldBtnState();
}

class _CircleHoldBtnState extends State<_CircleHoldBtn> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown:   (_) { setState(() => _pressed = true);  widget.onStart(); },
      onPointerUp:     (_) { setState(() => _pressed = false); widget.onStop();  },
      onPointerCancel: (_) { setState(() => _pressed = false); widget.onStop();  },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 80),
            width: widget.size, height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _pressed ? _kGold : Colors.transparent,
              border: Border.all(color: _pressed ? _kGold : _kGoldDim, width: 2.5),
            ),
            child: Icon(widget.icon,
              color: _pressed ? _kDark : _kGold,
              size: widget.iconSize,
            ),
          ),
          const SizedBox(height: 5),
          Text(widget.label, style: TextStyle(
            color: _pressed ? _kGold : _kGoldDim,
            fontSize: 9,
            letterSpacing: 1.5,
            fontWeight: FontWeight.bold,
          )),
        ],
      ),
    );
  }
}

// ── Status bar ───────────────────────────────────────────────────────────────
class _StatusBar extends StatelessWidget {
  final Telemetry? tel;
  const _StatusBar({required this.tel});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: _kPanel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _kGoldDim, width: 1.5),
      ),
      child: Row(children: [
        _Stat(
          icon: Icons.speed,
          label: 'Veloc.',
          value: tel == null ? '--' : '${tel!.speedKmh.toStringAsFixed(1)} km/h',
        ),
        _Div(),
        _Stat(
          icon: Icons.satellite_alt,
          label: 'Satélites',
          value: tel == null ? '--' : '${tel!.satellites}',
        ),
        _Div(),
        _Stat(
          icon: tel != null && tel!.gpsFix ? Icons.gps_fixed : Icons.gps_not_fixed,
          label: 'GPS',
          value: tel == null ? '--' : (tel!.gpsFix ? 'OK' : 'OFF'),
          valueColor: tel != null ? (tel!.gpsFix ? Colors.green.shade400 : Colors.red.shade400) : null,
        ),
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;
  const _Stat({required this.icon, required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Expanded(child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: Colors.green.shade400, size: 13),
        const SizedBox(height: 2),
        Text(value, style: TextStyle(color: valueColor ?? _kGold, fontSize: 12, fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(color: _kGoldDim, fontSize: 9)),
      ],
    ));
  }
}

class _Div extends StatelessWidget {
  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: 30, color: _kGoldDim.withValues(alpha: 0.4),
          margin: const EdgeInsets.symmetric(horizontal: 4));
}
