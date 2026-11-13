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
  final ValueNotifier<bool>? otaRunning;
  const SettingsScreen({super.key, required this.ble, this.initialPwmHelMin = 0, this.otaRunning});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int  _pwmHelMin      = 0;
  bool _apontandoNorte = false;
  bool _buzzerEnabled  = true;
  int  _headingOffset  = 0;
  bool _registerMode   = false;
  List<RemoteInfo> _remotes = [];

  // Opções avançadas
  bool   _advancedVisible = false;
  int    _calibTimeSeg    = 10;
  double _sliderCalibPwm  = 64.0;  // (160-100)/100*90+10
  double _sliderUsoPwm    = 91.3;  // (240-100)/155*90+10

  // Estado da bússola ($BSC)
  int _compassState = -1;
  StreamSubscription? _compassSub;

  // Ganhos da âncora (opções avançadas)
  AnchorGains _anchorGains = AnchorGains.defaults;
  StreamSubscription? _anchorGainsSub;

  // Incremento de aceleração (fora da senha)
  double _aceleracaoIncremento = 5.0;

  StreamSubscription? _hmnSub;
  StreamSubscription? _buzzerSub;
  StreamSubscription? _remotesSub;
  StreamSubscription? _hofSub;
  StreamSubscription? _regModeSub;
  StreamSubscription? _advCfgSub;

  // OTA state
  String? _latestVersion;
  String? _otaUrl;
  double? _otaProgress;
  String? _otaStatus;

  // Conversões PWM ↔ percentual
  double _pwmToCalibPct(int pwm) => (pwm - 100) / 100.0 * 90.0 + 10.0;
  int    _calibPctToPwm(double p) => ((p - 10) / 90.0 * 100 + 100).round().clamp(100, 200);
  double _pwmToUsoPct(int pwm)    => (pwm - 100) / 155.0 * 90.0 + 10.0;
  int    _usoPctToPwm(double p)   => ((p - 10) / 90.0 * 155 + 100).round().clamp(100, 255);

  @override
  void initState() {
    super.initState();
    _pwmHelMin  = widget.initialPwmHelMin;
    _hmnSub     = widget.ble.pwmHelMinStream.listen((v) => setState(() => _pwmHelMin = v));
    _buzzerSub  = widget.ble.buzzerStream.listen((v) => setState(() => _buzzerEnabled = v));
    _remotesSub = widget.ble.remotesStream.listen((v) => setState(() => _remotes = v));
    _hofSub     = widget.ble.headingOffsetStream.listen((v) => setState(() => _headingOffset = v));
    _regModeSub = widget.ble.remoteRegModeStream.listen((v) => setState(() => _registerMode = v));
    _advCfgSub  = widget.ble.advancedConfigStream.listen((cfg) => setState(() {
      _calibTimeSeg         = cfg.calibTimeSeg;
      _sliderCalibPwm       = _pwmToCalibPct(cfg.calibPwmGiro);
      _sliderUsoPwm         = _pwmToUsoPct(cfg.usoPwmGiro);
      _aceleracaoIncremento = cfg.aceleracaoIncremento.toDouble();
    }));
    _anchorGainsSub = widget.ble.anchorGainsStream.listen((g) => setState(() => _anchorGains = g));
    _compassState = widget.ble.compassState;
    _compassSub = widget.ble.compassStateStream.listen((v) => setState(() => _compassState = v));
    widget.ble.sendRequestAdvancedConfig();
  }

  @override
  void dispose() {
    _hmnSub?.cancel();
    _anchorGainsSub?.cancel();
    _compassSub?.cancel();
    _buzzerSub?.cancel();
    _remotesSub?.cancel();
    _hofSub?.cancel();
    _regModeSub?.cancel();
    _advCfgSub?.cancel();
    if (_registerMode) widget.ble.sendRemoteRegDisable();
    if (_apontandoNorte) widget.ble.sendPararNorte();
    super.dispose();
  }

  Future<bool> _showPasswordDialog() async {
    final controller = TextEditingController();
    bool obscure = true;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: _kPanel,
          title: const Row(children: [
            Icon(Icons.admin_panel_settings_outlined, color: _kGold, size: 22),
            SizedBox(width: 8),
            Text('Opções Avançadas', style: TextStyle(color: _kGold)),
          ]),
          content: TextField(
            controller: controller,
            obscureText: obscure,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Senha',
              hintStyle: const TextStyle(color: Colors.white38),
              enabledBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: _kGoldDim)),
              focusedBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: _kGold)),
              suffixIcon: IconButton(
                icon: Icon(obscure ? Icons.visibility_off : Icons.visibility,
                    color: _kGoldDim, size: 20),
                onPressed: () => setLocal(() => obscure = !obscure),
              ),
            ),
            onSubmitted: (_) => Navigator.pop(ctx, true),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar', style: TextStyle(color: _kGoldDim)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: _kGold),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Entrar', style: TextStyle(color: _kDark)),
            ),
          ],
        ),
      ),
    );
    if (result != true) return false;
    const adminPassword = 'Admin@2026';
    final ok = controller.text == adminPassword;
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Senha incorreta.', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.red,
        duration: Duration(seconds: 2),
      ));
    }
    return ok;
  }

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

  Future<void> _toggleBuzzer(bool value) async {
    if (!_verificarBLE()) return;
    if (value) {
      await widget.ble.sendBuzzerOn();
    } else {
      await widget.ble.sendBuzzerOff();
    }
  }

  Future<void> _changeOffset(int delta) async {
    if (!_verificarBLE()) return;
    final newVal = (_headingOffset + delta).clamp(-180, 180);
    await widget.ble.sendHeadingOffset(newVal);
  }

  Future<void> _resetOffset() async {
    if (!_verificarBLE()) return;
    await widget.ble.sendHeadingOffset(0);
  }

  Future<void> _toggleApontarNorte() async {
    if (!_verificarBLE()) return;
    if (_apontandoNorte) {
      await widget.ble.sendPararNorte();
      setState(() => _apontandoNorte = false);
    } else {
      await widget.ble.sendApontarNorte();
      setState(() => _apontandoNorte = true);
    }
  }

  Future<void> _incrementPwm() async {
    if (!_verificarBLE()) return;
    await widget.ble.sendPwmHelMinPlus();
  }

  Future<void> _decrementPwm() async {
    if (!_verificarBLE()) return;
    await widget.ble.sendPwmHelMinMinus();
  }

  Future<void> _calibrate() async {
    if (!_verificarBLE()) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _kPanel,
        title: const Text('Calibrar Bússola', style: TextStyle(color: _kGold)),
        content: const Text(
          'O motor vai girar para cada lado para calibrar e depois dar 1,5 volta para cada lado para verificar a calibração (cerca de 1 minuto).\n\nCertifique-se de que o barco esteja na água, com espaço livre e longe de estruturas metálicas.',
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

    await widget.ble.sendCalibrate();
    if (!mounted) return;

    // O diálogo acompanha as etapas enviadas pelo motor ($CAL:1/2/OK/ERR)
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CalibrationProgressDialog(
          stream: widget.ble.calibrationStream, calibTimeSeg: _calibTimeSeg),
    );
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
    if (confirm != true || !mounted) return;
    widget.otaRunning?.value = true;
    setState(() { _otaProgress = 0.0; _otaStatus = 'Iniciando...'; });
    final result = await widget.ble.performOta(
      _otaUrl!,
      _latestVersion!,
      onProgress: (p) { if (mounted) setState(() => _otaProgress = p); },
      onStatus: (st) { if (mounted) setState(() => _otaStatus = st); },
    );
    widget.otaRunning?.value = false;
    if (!mounted) return;
    setState(() { _otaProgress = null; _otaStatus = null; });
    // Se a atualização falhou no meio e a conexão caiu, tenta voltar sozinho
    if (!widget.ble.isConnected) widget.ble.reconnect();
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _kPanel,
        title: Row(children: [
          Icon(result.success ? Icons.check_circle : Icons.error,
              color: result.success ? Colors.green.shade400 : Colors.red.shade400),
          const SizedBox(width: 10),
          Expanded(child: Text(
            result.success ? 'Atualização concluída' : 'Atualização não concluída',
            style: const TextStyle(color: _kGold))),
        ]),
        content: Text(result.message, style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK', style: TextStyle(color: _kGold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          // ── 1. Controles Remotos ─────────────────────────────────
          _SectionTitle('Controles Remotos'),
          const SizedBox(height: 12),

          // ── Botão Opções Avançadas ────────────────────────────────
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: _advancedVisible ? Colors.red.shade900 : _kDark,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(
                    color: _advancedVisible ? Colors.red.shade400 : _kGoldDim,
                    width: 1.5,
                  ),
                ),
              ),
              icon: Icon(_advancedVisible
                  ? Icons.lock_open_outlined
                  : Icons.admin_panel_settings_outlined),
              label: Text(
                _advancedVisible ? 'Ocultar Opções' : 'Opções Avançadas',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              ),
              onPressed: () async {
                if (_advancedVisible) {
                  setState(() => _advancedVisible = false);
                } else {
                  if (!_verificarBLE()) return;
                  final ok = await _showPasswordDialog();
                  if (!ok || !mounted) return;
                  await widget.ble.sendRequestAdvancedConfig();
                  await widget.ble.sendRequestAnchorGains();
                  setState(() => _advancedVisible = true);
                }
              },
            ),
          ),

          // ── Painel de Opções Avançadas ────────────────────────────
          if (_advancedVisible) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _kPanel,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.red.shade900.withValues(alpha: 0.7)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [

                  // ── A) Tempo de Giro (Calibração) ─────────────────
                  const Text('Tempo de Giro na Calibração',
                      style: TextStyle(color: Colors.white70, fontSize: 13)),
                  const SizedBox(height: 4),
                  const Text('Duração do giro para cada lado durante a calibração da bússola.',
                      style: TextStyle(color: Colors.white38, fontSize: 11)),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _AdvBtn(
                        icon: Icons.remove,
                        onPressed: _calibTimeSeg > 1
                            ? () async {
                                final v = _calibTimeSeg - 1;
                                setState(() => _calibTimeSeg = v);
                                await widget.ble.sendCalibTimeSeg(v);
                              }
                            : null,
                      ),
                      const SizedBox(width: 20),
                      Column(
                        children: [
                          Text('$_calibTimeSeg',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 36,
                                  fontWeight: FontWeight.bold)),
                          const Text('segundos',
                              style: TextStyle(color: Colors.white38, fontSize: 11)),
                        ],
                      ),
                      const SizedBox(width: 20),
                      _AdvBtn(
                        icon: Icons.add,
                        onPressed: _calibTimeSeg < 10
                            ? () async {
                                final v = _calibTimeSeg + 1;
                                setState(() => _calibTimeSeg = v);
                                await widget.ble.sendCalibTimeSeg(v);
                              }
                            : null,
                      ),
                    ],
                  ),

                  const SizedBox(height: 20),
                  Divider(color: _kGoldDim.withValues(alpha: 0.3), height: 1),
                  const SizedBox(height: 16),

                  // ── B) Força de Giro (Calibração) ──────────────────
                  const Text('Força de Giro na Calibração',
                      style: TextStyle(color: Colors.white70, fontSize: 13)),
                  const SizedBox(height: 4),
                  const Text('Velocidade do motor durante a calibração da bússola.',
                      style: TextStyle(color: Colors.white38, fontSize: 11)),
                  const SizedBox(height: 8),
                  Row(children: [
                    const Text('10%',
                        style: TextStyle(color: Colors.white38, fontSize: 11)),
                    Expanded(
                      child: Slider(
                        value: _sliderCalibPwm.clamp(10.0, 100.0),
                        min: 10, max: 100,
                        divisions: 90,
                        activeColor: _kGold,
                        inactiveColor: _kGoldDim.withValues(alpha: 0.3),
                        label: '${_sliderCalibPwm.round()}%',
                        onChanged: (v) => setState(() => _sliderCalibPwm = v),
                        onChangeEnd: (v) =>
                            widget.ble.sendCalibPwmGiro(_calibPctToPwm(v)),
                      ),
                    ),
                    const Text('100%',
                        style: TextStyle(color: Colors.white38, fontSize: 11)),
                  ]),
                  Center(
                    child: Text('${_sliderCalibPwm.round()}%',
                        style: const TextStyle(
                            color: _kGold, fontWeight: FontWeight.bold)),
                  ),

                  const SizedBox(height: 20),
                  Divider(color: _kGoldDim.withValues(alpha: 0.3), height: 1),
                  const SizedBox(height: 16),

                  // ── C) Força de Giro (Uso manual) ─────────────────
                  const Text('Força de Giro para Uso',
                      style: TextStyle(color: Colors.white70, fontSize: 13)),
                  const SizedBox(height: 4),
                  const Text('PWM máximo do motor de giro ao usar os controles remotos.',
                      style: TextStyle(color: Colors.white38, fontSize: 11)),
                  const SizedBox(height: 8),
                  Row(children: [
                    const Text('10%',
                        style: TextStyle(color: Colors.white38, fontSize: 11)),
                    Expanded(
                      child: Slider(
                        value: _sliderUsoPwm.clamp(10.0, 100.0),
                        min: 10, max: 100,
                        divisions: 90,
                        activeColor: _kGold,
                        inactiveColor: _kGoldDim.withValues(alpha: 0.3),
                        label: '${_sliderUsoPwm.round()}%',
                        onChanged: (v) => setState(() => _sliderUsoPwm = v),
                        onChangeEnd: (v) =>
                            widget.ble.sendUsoPwmGiro(_usoPctToPwm(v)),
                      ),
                    ),
                    const Text('100%',
                        style: TextStyle(color: Colors.white38, fontSize: 11)),
                  ]),
                  Center(
                    child: Text('${_sliderUsoPwm.round()}%',
                        style: const TextStyle(
                            color: _kGold, fontWeight: FontWeight.bold)),
                  ),

                  const SizedBox(height: 20),
                  Divider(color: _kGoldDim.withValues(alpha: 0.3), height: 1),
                  const SizedBox(height: 16),

                  // ── D) Âncora — ajuste fino ───────────────────────
                  const Text('Âncora — Ajuste Fino',
                      style: TextStyle(color: Colors.white70, fontSize: 13)),
                  const SizedBox(height: 4),
                  const Text(
                      'Força: quanto o motor empurra por metro fora do ponto. '
                      'Correção: rapidez para aprender vento/correnteza. '
                      'Freio: quanto reduz o empuxo ao se aproximar. '
                      'Se o barco passar do ponto, aumente o Freio ou reduza a Força.',
                      style: TextStyle(color: Colors.white38, fontSize: 11)),
                  const SizedBox(height: 8),
                  _GainSlider(
                    label: 'Força (Kp)', value: _anchorGains.kp, min: 0, max: 100, divisions: 100,
                    onChanged: (v) => setState(() => _anchorGains =
                        AnchorGains(kp: v, ki: _anchorGains.ki, kd: _anchorGains.kd)),
                    onChangeEnd: (v) => widget.ble.sendAnchorKp(v),
                  ),
                  _GainSlider(
                    label: 'Correção (Ki)', value: _anchorGains.ki, min: 0, max: 20, divisions: 40,
                    onChanged: (v) => setState(() => _anchorGains =
                        AnchorGains(kp: _anchorGains.kp, ki: v, kd: _anchorGains.kd)),
                    onChangeEnd: (v) => widget.ble.sendAnchorKi(v),
                  ),
                  _GainSlider(
                    label: 'Freio (Kd)', value: _anchorGains.kd, min: 0, max: 150, divisions: 30,
                    onChanged: (v) => setState(() => _anchorGains =
                        AnchorGains(kp: _anchorGains.kp, ki: _anchorGains.ki, kd: v)),
                    onChangeEnd: (v) => widget.ble.sendAnchorKd(v),
                  ),
                  Center(
                    child: TextButton.icon(
                      onPressed: () => widget.ble.sendAnchorGainsReset(),
                      icon: const Icon(Icons.restart_alt, color: _kGoldDim, size: 18),
                      label: const Text('Restaurar padrão',
                          style: TextStyle(color: _kGoldDim, fontSize: 12)),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 12),

          // ── Botão Cadastrar Controle ──────────────────────────────
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: _registerMode ? Colors.red.shade700 : _kPanel,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(
                    color: _registerMode ? Colors.red.shade400 : _kGoldDim,
                    width: 1.5,
                  ),
                ),
              ),
              icon: Icon(_registerMode ? Icons.cancel_outlined : Icons.settings_remote),
              label: Text(
                _registerMode ? 'Cancelar Cadastro' : 'Cadastrar Controle',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              ),
              onPressed: () async {
                if (_registerMode) {
                  await widget.ble.sendRemoteRegDisable();
                } else {
                  if (!_verificarBLE()) return;
                  await widget.ble.sendRemoteRegEnable();
                }
              },
            ),
          ),
          const SizedBox(height: 12),
          if (_remotes.isEmpty)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _kPanel,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _kGoldDim.withValues(alpha: 0.5)),
              ),
              child: const Center(
                child: Text(
                  'Nenhum controle ativo.\nEnvie um comando pelo controle para exibir a bateria.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ),
            )
          else
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Container(
                decoration: BoxDecoration(
                  color: _kPanel,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _kGoldDim.withValues(alpha: 0.5)),
                ),
                child: Column(
                  children: _remotes.asMap().entries.map((e) {
                    final i = e.key;
                    final r = e.value;
                    final pct = r.batt.clamp(0, 100) / 100.0;
                    final battColor = r.batt >= 50
                        ? Colors.green.shade400
                        : r.batt >= 20
                            ? Colors.orange.shade400
                            : Colors.red.shade400;
                    return Column(
                      children: [
                        if (i > 0) Divider(height: 1, color: _kGoldDim.withValues(alpha: 0.3)),
                        Dismissible(
                          key: ValueKey(r.code),
                          direction: DismissDirection.endToStart,
                          background: Container(
                            color: Colors.red.shade700,
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 20),
                            child: const Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                Icon(Icons.delete_outline, color: Colors.white, size: 22),
                                SizedBox(width: 6),
                                Text('Excluir',
                                    style: TextStyle(color: Colors.white,
                                        fontWeight: FontWeight.bold, fontSize: 13)),
                              ],
                            ),
                          ),
                          confirmDismiss: (direction) async {
                            if (!_verificarBLE()) return false;
                            return showDialog<bool>(
                              context: context,
                              builder: (_) => AlertDialog(
                                backgroundColor: _kPanel,
                                title: const Text('Excluir controle?',
                                    style: TextStyle(color: _kGold)),
                                content: Text(
                                  'O controle de código ${r.code} será removido da memória do motor.\n\nEle não poderá mais enviar comandos até ser recadastrado.',
                                  style: const TextStyle(color: Colors.white70),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(context, false),
                                    child: const Text('Cancelar',
                                        style: TextStyle(color: _kGoldDim)),
                                  ),
                                  ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.red.shade700),
                                    onPressed: () => Navigator.pop(context, true),
                                    child: const Text('Excluir',
                                        style: TextStyle(color: Colors.white)),
                                  ),
                                ],
                              ),
                            );
                          },
                          onDismissed: (direction) {
                            setState(() => _remotes =
                                _remotes.where((x) => x.code != r.code).toList());
                            widget.ble.sendRemoveRemote(r.code);
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            child: Row(
                              children: [
                                const Icon(Icons.settings_remote, color: _kGoldDim, size: 20),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text('Código ${r.code}',
                                      style: const TextStyle(color: Colors.white70, fontSize: 13)),
                                ),
                                if (r.batt < 0)
                                  const Text('–',
                                      style: TextStyle(color: Colors.white38, fontSize: 13))
                                else ...[
                                  SizedBox(
                                    width: 80,
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(4),
                                      child: LinearProgressIndicator(
                                        value: pct,
                                        minHeight: 8,
                                        backgroundColor: Colors.white12,
                                        valueColor: AlwaysStoppedAnimation<Color>(battColor),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text('${r.batt}%',
                                      style: TextStyle(
                                          color: battColor,
                                          fontSize: 13,
                                          fontWeight: FontWeight.bold)),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ],
                    );
                  }).toList(),
                ),
              ),
            ),

          // ── 2. Buzzer ────────────────────────────────────────────
          const SizedBox(height: 28),
          _SectionTitle('Buzzer'),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: _kPanel,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _kGoldDim.withValues(alpha: 0.5)),
            ),
            child: Row(
              children: [
                const Icon(Icons.volume_up_outlined, color: _kGoldDim, size: 22),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('Buzzer do motor',
                      style: TextStyle(color: Colors.white70, fontSize: 14)),
                ),
                Switch(
                  value: _buzzerEnabled,
                  activeThumbColor: _kDark,
                  activeTrackColor: _kGold,
                  inactiveThumbColor: Colors.grey,
                  inactiveTrackColor: Colors.white12,
                  onChanged: _toggleBuzzer,
                ),
              ],
            ),
          ),

          // ── 3. Calibrações ───────────────────────────────────────
          const SizedBox(height: 28),
          _SectionTitle('Calibrações'),
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

                // ── Calibrar Bússola ──────────────────────────────
                const Text('Calibrar Bússola',
                    style: TextStyle(color: Colors.white70, fontSize: 13)),
                const SizedBox(height: 4),
                const Text(
                  'Obrigatória com o motor instalado: sem ela a âncora, o norte e o aponta-norte '
                  'ficam bloqueados. O motor gira para cada lado e depois verifica a calibração. '
                  'Execute com o barco na água, longe de estruturas metálicas.',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
                const SizedBox(height: 8),
                _CompassStateChip(state: _compassState),
                const SizedBox(height: 12),
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

                // ── Offset da Bússola ─────────────────────────────
                const SizedBox(height: 20),
                Divider(color: _kGoldDim.withValues(alpha: 0.3), height: 1),
                const SizedBox(height: 16),
                const Text('Offset da Bússola',
                    style: TextStyle(color: Colors.white70, fontSize: 13)),
                const SizedBox(height: 4),
                const Text(
                  'Corrija o desvio de direção da âncora. '
                  'Ative a âncora, afaste o barco e ajuste até o motor apontar corretamente. '
                  'Salvo automaticamente no motor.',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _OffsetBtn(
                      label: '–',
                      onPressed: _headingOffset > -180
                          ? () => _changeOffset(-1)
                          : null,
                    ),
                    const SizedBox(width: 20),
                    Column(
                      children: [
                        Text(
                          '${_headingOffset >= 0 ? '+' : ''}$_headingOffset°',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 36,
                            fontWeight: FontWeight.bold,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                        const Text('offset', style: TextStyle(color: Colors.white38, fontSize: 11)),
                      ],
                    ),
                    const SizedBox(width: 20),
                    _OffsetBtn(
                      label: '+',
                      onPressed: _headingOffset < 180
                          ? () => _changeOffset(1)
                          : null,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _kGoldDim,
                      side: const BorderSide(color: _kGoldDim),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: const Icon(Icons.restart_alt, size: 18),
                    label: const Text('Resetar offset', style: TextStyle(fontSize: 13)),
                    onPressed: _headingOffset != 0 ? _resetOffset : null,
                  ),
                ),

                // ── Apontar para Norte ────────────────────────────
                const SizedBox(height: 20),
                Divider(color: _kGoldDim.withValues(alpha: 0.3), height: 1),
                const SizedBox(height: 16),
                const Text('Apontar para Norte',
                    style: TextStyle(color: Colors.white70, fontSize: 13)),
                const SizedBox(height: 4),
                const Text(
                  'Gira o motor para 0° (Norte) com PWM fixo. '
                  'Útil para verificar a calibração da bússola.',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _apontandoNorte ? Colors.red.shade800 : _kPanel,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: BorderSide(
                          color: _apontandoNorte ? Colors.red.shade400 : _kGoldDim,
                          width: 1.5,
                        ),
                      ),
                    ),
                    icon: Icon(_apontandoNorte ? Icons.stop_circle_outlined : Icons.navigation),
                    label: Text(
                      _apontandoNorte ? 'Parar' : 'Apontar para Norte (0°)',
                      style: const TextStyle(fontSize: 15),
                    ),
                    onPressed: _toggleApontarNorte,
                  ),
                ),
              ],
            ),
          ),

          // ── 4. Motor ─────────────────────────────────────────────
          const SizedBox(height: 28),
          _SectionTitle('Motor'),
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

                const SizedBox(height: 20),
                Divider(color: _kGoldDim.withValues(alpha: 0.3), height: 1),
                const SizedBox(height: 16),

                const Text('Incremento de Aceleração',
                    style: TextStyle(color: Colors.white70, fontSize: 13)),
                const SizedBox(height: 4),
                const Text(
                  'Quanto o acelerador sobe ou desce a cada clique, pelo app ou pelo controle remoto.',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  const Text('2',
                      style: TextStyle(color: Colors.white38, fontSize: 11)),
                  Expanded(
                    child: Slider(
                      value: _aceleracaoIncremento.clamp(2.0, 20.0),
                      min: 2, max: 20,
                      divisions: 18,
                      activeColor: _kGold,
                      inactiveColor: _kGoldDim.withValues(alpha: 0.3),
                      label: '${_aceleracaoIncremento.round()}',
                      onChanged: (v) => setState(() => _aceleracaoIncremento = v),
                      onChangeEnd: (v) =>
                          widget.ble.sendAceleracaoIncremento(v.round()),
                    ),
                  ),
                  const Text('20',
                      style: TextStyle(color: Colors.white38, fontSize: 11)),
                ]),
                Center(
                  child: Text('${_aceleracaoIncremento.round()}',
                      style: const TextStyle(
                          color: _kGold, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),

          // ── 5. Atualização de Firmware (OTA) ─────────────────────
          const SizedBox(height: 28),
          _SectionTitle('Atualização de Firmware'),
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
              if (_otaStatus != null) ...[
                Text(_otaStatus!, style: const TextStyle(color: Colors.white70, fontSize: 13)),
                const SizedBox(height: 8),
              ],
              LinearProgressIndicator(
                  // Indeterminado fora do envio (reinício, reconexão, validação)
                  value: _otaStatus == 'Enviando firmware...' ? _otaProgress : null,
                  color: _kGold,
                  backgroundColor: _kGoldDim.withValues(alpha: 0.3)),
              const SizedBox(height: 8),
              if (_otaStatus == 'Enviando firmware...')
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

          // ── 6. Procurar novo motor ────────────────────────────────
          const SizedBox(height: 28),
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
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.bluetooth_searching, color: _kGoldDim, size: 20),
                  SizedBox(width: 8),
                  Text('Procurar novo motor',
                      style: TextStyle(color: _kGoldDim, fontSize: 14, fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          ),
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

// ── Offset +/- button ─────────────────────────────────────────────────────────
class _OffsetBtn extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  const _OffsetBtn({required this.label, required this.onPressed});

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
// ── Advanced +/- button (spinner) ────────────────────────────────────────────
class _CompassStateChip extends StatelessWidget {
  final int state;
  const _CompassStateChip({required this.state});

  @override
  Widget build(BuildContext context) {
    final (IconData icon, Color color, String text) = switch (state) {
      1 => (Icons.check_circle, Colors.green.shade400, 'Bússola calibrada'),
      0 => (Icons.warning_amber, Colors.orange.shade400, 'Bússola NÃO calibrada'),
      2 => (Icons.error, Colors.red.shade400, 'Calibração inválida — recalibre'),
      3 => (Icons.error, Colors.red.shade400, 'Bússola não encontrada'),
      _ => (Icons.help_outline, Colors.white38, 'Estado da bússola desconhecido'),
    };
    return Row(children: [
      Icon(icon, color: color, size: 16),
      const SizedBox(width: 6),
      Text(text, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold)),
    ]);
  }
}

class _GainSlider extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  const _GainSlider({
    required this.label, required this.value, required this.min, required this.max,
    required this.divisions, required this.onChanged, required this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) {
    final text = value == value.roundToDouble()
        ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
    return Row(children: [
      SizedBox(width: 96,
          child: Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12))),
      Expanded(
        child: Slider(
          value: value.clamp(min, max),
          min: min, max: max, divisions: divisions,
          activeColor: _kGold,
          inactiveColor: _kGoldDim.withValues(alpha: 0.3),
          label: text,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      ),
      SizedBox(width: 36,
          child: Text(text, textAlign: TextAlign.right,
              style: const TextStyle(color: _kGold, fontWeight: FontWeight.bold))),
    ]);
  }
}

class _AdvBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  const _AdvBtn({required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: onPressed != null ? _kGoldDim : Colors.grey.shade800,
        ),
        child: Icon(icon,
            color: onPressed != null ? Colors.white : Colors.white24, size: 22),
      ),
    );
  }
}

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
  final Stream<String> stream;
  final int calibTimeSeg;
  const _CalibrationProgressDialog({required this.stream, required this.calibTimeSeg});

  @override
  State<_CalibrationProgressDialog> createState() => _CalibrationProgressDialogState();
}

class _CalibrationProgressDialogState extends State<_CalibrationProgressDialog> {
  int _elapsed = 0;
  Timer? _timer;
  StreamSubscription<String>? _sub;
  String _stage = '1';        // 1 = calibrando, 2 = verificando
  bool? _ok;                  // resultado final
  String _message = '';

  // Calibração (2 lados + pausas) e verificação (1,5 volta para cada lado)
  int get _expected => widget.calibTimeSeg * 2 + 3 + 30;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _ok != null) return;
      setState(() => _elapsed++);
      // Sem resposta do motor bem depois do esperado
      if (_elapsed > _expected + 60) {
        _finish(false, 'O motor não informou o resultado. Verifique a conexão e repita a calibração.');
      }
    });
    _sub = widget.stream.listen((ev) {
      if (!mounted) return;
      if (ev == '1' || ev == '2') {
        setState(() => _stage = ev);
      } else if (ev == 'OK') {
        _finish(true, 'Calibração aplicada e verificada: o rumo foi lido nos 360°, sem falhas.');
      } else if (ev.startsWith('ERR:')) {
        _finish(false, _errorText(ev.substring(4)));
      }
    });
  }

  void _finish(bool ok, String msg) {
    _timer?.cancel();
    setState(() { _ok = ok; _message = msg; });
  }

  static String _errorText(String code) {
    final keep = '\n\nA calibração anterior foi mantida.';
    final lado = code.contains('_esq') ? ' (giro para a esquerda)' : code.contains('_dir') ? ' (giro para a direita)' : '';
    if (code.startsWith('sem_leituras')) {
      return 'A bússola não registrou variação suficiente. O motor girou de verdade? Confira a ligação da bússola.$keep';
    }
    if (code.startsWith('eixos_desproporcionais')) {
      return 'Leituras muito distorcidas. Afaste peças metálicas da cabeça do motor e repita.$keep';
    }
    if (code.startsWith('giro_incompleto')) {
      return 'O motor não completou a volta e meia de verificação$lado. Verifique se o giro está livre (cabo, obstáculo).$keep';
    }
    if (code.startsWith('setores')) {
      return 'Ainda existem faixas do rumo sem leitura$lado. Repita a calibração com o motor girando livremente.$keep';
    }
    if (code.startsWith('saltos')) {
      return 'O rumo deu saltos durante a volta$lado: a bússola não está bem calibrada. Repita a calibração.$keep';
    }
    if (code.startsWith('campo_irregular')) {
      return 'A intensidade do campo variou demais na volta$lado: há interferência magnética (metal próximo, cabos de potência). Repita longe de estruturas metálicas.$keep';
    }
    return 'Falha na calibração ($code).$keep';
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_ok != null) {
      return AlertDialog(
        backgroundColor: _kPanel,
        title: Row(children: [
          Icon(_ok! ? Icons.check_circle : Icons.error,
              color: _ok! ? Colors.green.shade400 : Colors.red.shade400),
          const SizedBox(width: 10),
          Expanded(child: Text(_ok! ? 'Bússola calibrada' : 'Calibração reprovada',
              style: const TextStyle(color: _kGold))),
        ]),
        content: Text(_message, style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK', style: TextStyle(color: _kGold)),
          ),
        ],
      );
    }
    final progress = (_elapsed / _expected).clamp(0.0, 0.97);
    final phase = _stage == '2'
        ? 'Verificando: 1,5 volta para cada lado...'
        : 'Calibrando: girando para cada lado...';
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
          Text('${_elapsed}s', style: const TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      ),
    );
  }
}
