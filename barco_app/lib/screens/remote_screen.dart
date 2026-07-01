import 'dart:async';
import 'package:flutter/material.dart';
import '../services/ble_service.dart';
import '../models/telemetry.dart';

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

  // ── Aceleracao hold ──────────────────────────────────────────────
  void _startAcel(bool plus) {
    _sendAcelOnce(plus);
    _acelTimer = Timer.periodic(const Duration(milliseconds: 120), (_) => _sendAcelOnce(plus));
  }

  void _stopAcel() {
    _acelTimer?.cancel();
    _acelTimer = null;
  }

  void _sendAcelOnce(bool plus) {
    if (plus) { widget.ble.sendAcelPlus(); } else { widget.ble.sendAcelMinus(); }
  }

  // ── Giro hold — reenvia a cada 100ms; firmware para pelo holdTimeout ─
  void _startGiro(bool right) {
    final send = right ? widget.ble.sendGiroDirStart : widget.ble.sendGiroEsqStart;
    send();
    _giroTimer = Timer.periodic(const Duration(milliseconds: 100), (_) => send());
  }

  void _stopGiro() {
    _giroTimer?.cancel();
    _giroTimer = null;
  }

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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        children: [
          // ── Painel de status ─────────────────────────────────────
          _StatusBar(tel: tel),
          const SizedBox(height: 16),

          // ── Linha 1: Ancora + Norte ───────────────────────────────
          Row(children: [
            Expanded(child: _ToggleBtn(
              label: anchorActive ? 'PARAR ANCORA' : 'ANCORA',
              icon: Icons.anchor,
              active: anchorActive,
              activeColor: Colors.red.shade700,
              inactiveColor: Colors.blue.shade800,
              onTap: widget.ble.sendToggleAnchor,
            )),
            const SizedBox(width: 10),
            Expanded(child: _ToggleBtn(
              label: northActive ? 'PARAR NORTE' : 'MODO NORTE',
              icon: Icons.explore,
              active: northActive,
              activeColor: Colors.orange.shade800,
              inactiveColor: Colors.teal.shade800,
              onTap: widget.ble.sendToggleNorth,
            )),
          ]),
          const SizedBox(height: 10),

          // ── Linha 2: Motor ON/OFF ─────────────────────────────────
          _ToggleBtn(
            label: 'MOTOR',
            icon: Icons.power_settings_new,
            active: false,
            activeColor: Colors.green.shade700,
            inactiveColor: Colors.grey.shade800,
            onTap: widget.ble.sendToggleMotor,
          ),
          const SizedBox(height: 20),

          // ── Linha 3: Giro ─────────────────────────────────────────
          _SectionLabel('GIRO'),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: _AcelBtn(
              label: '◄  ESQUERDA',
              color: Colors.indigo.shade700,
              onStart: () => _startGiro(false),
              onStop:  _stopGiro,
            )),
            const SizedBox(width: 10),
            Expanded(child: _AcelBtn(
              label: 'DIREITA  ►',
              color: Colors.indigo.shade700,
              onStart: () => _startGiro(true),
              onStop:  _stopGiro,
            )),
          ]),
          const SizedBox(height: 20),

          // ── Linha 4: Acelerador ───────────────────────────────────
          _SectionLabel('ACELERADOR'),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: _AcelBtn(
              label: 'ACEL  –',
              color: Colors.deepOrange.shade800,
              onStart: () => _startAcel(false),
              onStop:  _stopAcel,
            )),
            const SizedBox(width: 10),
            Expanded(child: _AcelBtn(
              label: 'ACEL  +',
              color: Colors.green.shade800,
              onStart: () => _startAcel(true),
              onStop:  _stopAcel,
            )),
          ]),
          const SizedBox(height: 20),

          // ── Linha 5: Subir / Descer ───────────────────────────────
          _SectionLabel('SUBIR / DESCER'),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: _HoldBtn(
              label: '▼  DESCER',
              color: Colors.brown.shade700,
              onStart: widget.ble.sendDownStart,
              onStop:  widget.ble.sendDownStop,
            )),
            const SizedBox(width: 10),
            Expanded(child: _HoldBtn(
              label: '▲  SUBIR',
              color: Colors.brown.shade700,
              onStart: widget.ble.sendUpStart,
              onStop:  widget.ble.sendUpStop,
            )),
          ]),
          const SizedBox(height: 16),
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
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1B2A3B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(children: [
        _Stat(icon: Icons.speed,   label: 'Veloc.',  value: tel == null ? '--' : '${tel!.speedKmh.toStringAsFixed(1)} km/h'),
        _Divider(),
        _Stat(icon: Icons.explore, label: 'Heading', value: tel == null ? '--' : '${tel!.heading.toStringAsFixed(0)}°'),
        _Divider(),
        _Stat(icon: Icons.straighten, label: 'Dist.',  value: (tel == null || !tel!.anchorActive) ? '--' : '${tel!.distToAnchor.toStringAsFixed(1)} m'),
        _Divider(),
        _Stat(icon: Icons.tune,    label: 'PWM',    value: tel == null ? '--' : '${tel!.pwm}'),
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
        Icon(icon, color: Colors.white54, size: 14),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(color: Colors.white38, fontSize: 9)),
      ],
    ));
  }
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: 32, color: Colors.white12, margin: const EdgeInsets.symmetric(horizontal: 4));
}

// ── Section label ─────────────────────────────────────────────────────────────
class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Row(children: [
    Expanded(child: Divider(color: Colors.white12)),
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text(text, style: const TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.5)),
    ),
    Expanded(child: Divider(color: Colors.white12)),
  ]);
}

// ── Toggle button (ancora, norte, motor) ─────────────────────────────────────
class _ToggleBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool active;
  final Color activeColor;
  final Color inactiveColor;
  final Future<void> Function() onTap;
  const _ToggleBtn({
    required this.label,
    required this.icon,
    required this.active,
    required this.activeColor,
    required this.inactiveColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 60,
        decoration: BoxDecoration(
          color: active ? activeColor : inactiveColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: active ? activeColor.withValues(alpha: 0.6) : Colors.white12),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, color: Colors.white, size: 22),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
        ]),
      ),
    );
  }
}

// ── Hold button — envia start/stop via Listener ───────────────────────────────
class _HoldBtn extends StatefulWidget {
  final String label;
  final Color color;
  final Future<void> Function() onStart;
  final Future<void> Function() onStop;
  const _HoldBtn({required this.label, required this.color, required this.onStart, required this.onStop});

  @override
  State<_HoldBtn> createState() => _HoldBtnState();
}

class _HoldBtnState extends State<_HoldBtn> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) { setState(() => _pressed = true);  widget.onStart(); },
      onPointerUp:   (_) { setState(() => _pressed = false); widget.onStop();  },
      onPointerCancel: (_) { setState(() => _pressed = false); widget.onStop(); },
      child: Container(
        height: 64,
        decoration: BoxDecoration(
          color: _pressed ? widget.color : widget.color.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _pressed ? Colors.white54 : Colors.white12),
          boxShadow: _pressed
              ? [BoxShadow(color: widget.color.withValues(alpha: 0.5), blurRadius: 12)]
              : null,
        ),
        child: Center(
          child: Text(widget.label,
              style: TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: _pressed ? FontWeight.bold : FontWeight.w500,
              )),
        ),
      ),
    );
  }
}

// ── Acel button — usa Timer interno enquanto pressionado ─────────────────────
class _AcelBtn extends StatefulWidget {
  final String label;
  final Color color;
  final VoidCallback onStart;
  final VoidCallback onStop;
  const _AcelBtn({required this.label, required this.color, required this.onStart, required this.onStop});

  @override
  State<_AcelBtn> createState() => _AcelBtnState();
}

class _AcelBtnState extends State<_AcelBtn> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) { setState(() => _pressed = true);  widget.onStart(); },
      onPointerUp:   (_) { setState(() => _pressed = false); widget.onStop();  },
      onPointerCancel: (_) { setState(() => _pressed = false); widget.onStop(); },
      child: Container(
        height: 64,
        decoration: BoxDecoration(
          color: _pressed ? widget.color : widget.color.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _pressed ? Colors.white54 : Colors.white12),
          boxShadow: _pressed
              ? [BoxShadow(color: widget.color.withValues(alpha: 0.5), blurRadius: 12)]
              : null,
        ),
        child: Center(
          child: Text(widget.label,
              style: TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: _pressed ? FontWeight.bold : FontWeight.w500,
              )),
        ),
      ),
    );
  }
}
