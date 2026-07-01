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

  // ── Acelerador hold ──────────────────────────────────────────────
  void _startAcel(bool plus) {
    _sendAcelOnce(plus);
    _acelTimer = Timer.periodic(const Duration(milliseconds: 120), (_) => _sendAcelOnce(plus));
  }

  void _stopAcel() { _acelTimer?.cancel(); _acelTimer = null; }

  void _sendAcelOnce(bool plus) {
    if (plus) { widget.ble.sendAcelPlus(); } else { widget.ble.sendAcelMinus(); }
  }

  // ── Giro hold (reenvia 100ms; firmware para pelo holdTimeout) ───
  void _startGiro(bool right) {
    final send = right ? widget.ble.sendGiroDirStart : widget.ble.sendGiroEsqStart;
    send();
    _giroTimer = Timer.periodic(const Duration(milliseconds: 100), (_) => send());
  }

  void _stopGiro() { _giroTimer?.cancel(); _giroTimer = null; }

  @override
  void dispose() {
    _acelTimer?.cancel();
    _giroTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tel = widget.tel;
    final anchorActive = tel?.anchorActive ?? false;
    final northActive  = tel?.northActive  ?? false;

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
            child: Column(
              children: [
                // + (Acelerar) — pill
                _PillHoldBtn(
                  label: '+',
                  onStart: () => _startAcel(true),
                  onStop:  _stopAcel,
                ),
                const SizedBox(height: 20),

                // ◄  Motor  ►
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Giro esquerda
                    _ArrowHoldBtn(
                      icon: Icons.arrow_back_ios_rounded,
                      onStart: () => _startGiro(false),
                      onStop:  _stopGiro,
                    ),

                    // Motor (centro — toque simples)
                    _MotorCircleBtn(onTap: widget.ble.sendToggleMotor),

                    // Giro direita
                    _ArrowHoldBtn(
                      icon: Icons.arrow_forward_ios_rounded,
                      onStart: () => _startGiro(true),
                      onStop:  _stopGiro,
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // - (Desacelerar) — pill
                _PillHoldBtn(
                  label: '–',
                  onStart: () => _startAcel(false),
                  onStop:  _stopAcel,
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // ══════════════════════════════════════════════════════════
          // PAINEL INFERIOR  —  Ancora + Norte + Subir + Descer
          // ══════════════════════════════════════════════════════════
          _GoldPanel(
            child: Column(
              children: [
                // Ancora  |  Norte (mira)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _CircleToggleBtn(
                      icon: Icons.anchor,
                      label: 'ÂNCORA',
                      active: anchorActive,
                      onTap: widget.ble.sendToggleAnchor,
                    ),
                    _CircleToggleBtn(
                      icon: Icons.gps_fixed,
                      label: 'NORTE',
                      active: northActive,
                      onTap: widget.ble.sendToggleNorth,
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Linha com marca e botoes subir/descer
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _CircleHoldBtn(
                      icon: Icons.keyboard_arrow_up_rounded,
                      label: 'SUBIR',
                      onStart: widget.ble.sendUpStart,
                      onStop:  widget.ble.sendUpStop,
                    ),
                    // Marca central
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
                      onStart: widget.ble.sendDownStart,
                      onStop:  widget.ble.sendDownStop,
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
  const _GoldPanel({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
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
        height: 46,
        decoration: BoxDecoration(
          color: _pressed ? _kGold : Colors.transparent,
          borderRadius: BorderRadius.circular(23),
          border: Border.all(color: _pressed ? _kGold : _kGoldDim, width: 2),
        ),
        child: Center(
          child: Text(
            widget.label,
            style: TextStyle(
              color: _pressed ? _kDark : _kGold,
              fontSize: 26,
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
        width: 70, height: 70,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _pressed ? _kGold : Colors.transparent,
          border: Border.all(color: _pressed ? _kGold : _kGoldDim, width: 2),
        ),
        child: Icon(widget.icon,
          color: _pressed ? _kDark : _kGold,
          size: 30,
        ),
      ),
    );
  }
}

// ── Motor circle button (centro) ─────────────────────────────────────────────
class _MotorCircleBtn extends StatefulWidget {
  final Future<void> Function() onTap;
  const _MotorCircleBtn({required this.onTap});

  @override
  State<_MotorCircleBtn> createState() => _MotorCircleBtnState();
}

class _MotorCircleBtnState extends State<_MotorCircleBtn> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown:   (_) => setState(() => _pressed = true),
      onTapUp:     (_) { setState(() => _pressed = false); widget.onTap(); },
      onTapCancel: ()  => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        width: 78, height: 78,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _pressed ? _kGold : Colors.transparent,
          border: Border.all(color: _kGold, width: 2.5),
          boxShadow: _pressed
              ? [BoxShadow(color: _kGold.withValues(alpha: 0.4), blurRadius: 16)]
              : null,
        ),
        child: Icon(Icons.wind_power,
          color: _pressed ? _kDark : _kGold,
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
  const _CircleToggleBtn({
    required this.icon, required this.label,
    required this.active, required this.onTap,
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
            width: 72, height: 72,
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
              size: 34,
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
  const _CircleHoldBtn({
    required this.icon, required this.label,
    required this.onStart, required this.onStop,
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
            width: 72, height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _pressed ? _kGold : Colors.transparent,
              border: Border.all(color: _pressed ? _kGold : _kGoldDim, width: 2.5),
            ),
            child: Icon(widget.icon,
              color: _pressed ? _kDark : _kGold,
              size: 38,
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
        _Stat(icon: Icons.speed,      label: 'Veloc.',  value: tel == null ? '--' : '${tel!.speedKmh.toStringAsFixed(1)} km/h'),
        _Div(),
        _Stat(icon: Icons.explore,    label: 'Heading', value: tel == null ? '--' : '${tel!.heading.toStringAsFixed(0)}°'),
        _Div(),
        _Stat(icon: Icons.straighten, label: 'Dist.',   value: (tel == null || !tel!.anchorActive) ? '--' : '${tel!.distToAnchor.toStringAsFixed(1)} m'),
        _Div(),
        _Stat(icon: Icons.tune,       label: 'PWM',     value: tel == null ? '--' : '${tel!.pwm}'),
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _Stat({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: _kGoldDim, size: 13),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(color: _kGold, fontSize: 12, fontWeight: FontWeight.bold)),
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
