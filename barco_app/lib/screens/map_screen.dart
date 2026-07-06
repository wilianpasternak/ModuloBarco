import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import '../models/fishing_spot.dart';
import '../models/telemetry.dart';
import '../services/ble_service.dart';
import '../services/fishing_spot_service.dart';

const _kGold    = Color(0xFFD4A800);
const _kGoldDim = Color(0xFF6B5400);
const _kPanel   = Color(0xFF1A1A10);
const _kDark    = Color(0xFF0F0F08);

class MapScreen extends StatefulWidget {
  final BleService ble;
  final Telemetry? tel;
  const MapScreen({super.key, required this.ble, this.tel});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final _mapController  = MapController();
  final _spotService    = FishingSpotService();
  LatLng? _anchorPoint;
  bool    _mapReady     = false;
  LatLng? _lastMovedTo;
  List<FishingSpot> _spots = [];

  @override
  void initState() {
    super.initState();
    _loadSpots();
  }

  Future<void> _loadSpots() async {
    final spots = await _spotService.load();
    if (mounted) setState(() => _spots = spots);
  }

  @override
  void didUpdateWidget(MapScreen old) {
    super.didUpdateWidget(old);
    final tel = widget.tel;
    if (tel == null) return;

    if (tel.anchorActive && _anchorPoint == null) {
      _anchorPoint = LatLng(tel.lat, tel.lon);
    }
    if (!tel.anchorActive) _anchorPoint = null;

    if (_mapReady && tel.hasValidPosition) {
      final pos = LatLng(tel.lat, tel.lon);
      if (_lastMovedTo == null ||
          (pos.latitude  - _lastMovedTo!.latitude).abs()  > 0.000005 ||
          (pos.longitude - _lastMovedTo!.longitude).abs() > 0.000005) {
        _mapController.move(pos, _mapController.camera.zoom);
        _lastMovedTo = pos;
      }
    }
  }

  // ── Geolocator ────────────────────────────────────────────────────────────

  Future<Position?> _getPhonePosition() async {
    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Permissão de localização negada.',
              style: TextStyle(color: Colors.white)),
          backgroundColor: Colors.red,
        ));
      }
      return null;
    }

    if (!mounted) return null;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: CircularProgressIndicator(color: _kGold),
      ),
    );

    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      return pos;
    } catch (_) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Não foi possível obter a localização.',
              style: TextStyle(color: Colors.white)),
          backgroundColor: Colors.red,
        ));
      }
      return null;
    }
  }

  // ── Adicionar ponto ───────────────────────────────────────────────────────

  Future<void> _addSpot() async {
    final pos = await _getPhonePosition();
    if (pos == null || !mounted) return;

    final result = await showModalBottomSheet<FishingSpot?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _kPanel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _AddSpotSheet(lat: pos.latitude, lng: pos.longitude),
    );

    if (result != null) {
      final spots = await _spotService.add(result);
      if (mounted) setState(() => _spots = spots);
    }
  }

  // ── Lista de pontos ───────────────────────────────────────────────────────

  void _showSpotsList() {
    showModalBottomSheet(
      context: context,
      backgroundColor: _kPanel,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        maxChildSize: 0.92,
        minChildSize: 0.3,
        expand: false,
        builder: (ctx, scrollCtrl) => Column(
          children: [
            // Handle
            Container(
              margin: const EdgeInsets.symmetric(vertical: 12),
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Text('Pontos de Pesca',
                style: TextStyle(color: _kGold, fontSize: 16,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('${_spots.length} ponto(s) cadastrado(s)',
                style: const TextStyle(color: Colors.white38, fontSize: 11)),
            const SizedBox(height: 8),
            Divider(color: _kGoldDim.withValues(alpha: 0.4), height: 1),
            Expanded(
              child: _spots.isEmpty
                  ? const Center(
                      child: Text(
                        'Nenhum ponto cadastrado.\nToque em + no mapa para adicionar.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white38, fontSize: 13),
                      ),
                    )
                  : ListView.separated(
                      controller: scrollCtrl,
                      itemCount: _spots.length,
                      separatorBuilder: (_, __) =>
                          Divider(height: 1, color: _kGoldDim.withValues(alpha: 0.3)),
                      itemBuilder: (_, i) {
                        final s = _spots[i];
                        return ListTile(
                          leading: Image.asset('assets/fish_point.png',
                              width: 40, height: 40, fit: BoxFit.contain),
                          title: Text(
                            s.description.isNotEmpty ? s.description : 'Sem descrição',
                            style: const TextStyle(color: Colors.white70, fontSize: 13),
                          ),
                          subtitle: Text(
                            '${s.fishSpecies.isNotEmpty ? s.fishSpecies : '–'}  ·  ${_fmtDate(s.dateTime)}',
                            style: const TextStyle(color: Colors.white38, fontSize: 11),
                          ),
                          trailing: const Icon(Icons.chevron_right, color: _kGoldDim),
                          onTap: () {
                            Navigator.pop(ctx);
                            Future.delayed(const Duration(milliseconds: 300), () {
                              if (_mapReady) {
                                _mapController.move(LatLng(s.lat, s.lng), 17.0);
                              }
                            });
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Detalhe do ponto ──────────────────────────────────────────────────────

  void _showSpotDetail(FishingSpot spot) {
    showModalBottomSheet(
      context: context,
      backgroundColor: _kPanel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Image.asset('assets/fish_point.png', width: 36, height: 36, fit: BoxFit.contain),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  spot.description.isNotEmpty ? spot.description : 'Ponto de Pesca',
                  style: const TextStyle(color: _kGold, fontSize: 17,
                      fontWeight: FontWeight.bold),
                ),
              ),
            ]),
            const SizedBox(height: 16),
            _DetailRow(label: 'Data', value: _fmtDate(spot.dateTime)),
            _DetailRow(label: 'Espécie',
                value: spot.fishSpecies.isNotEmpty ? spot.fishSpecies : '–'),
            _DetailRow(label: 'Quantidade',
                value: spot.fishCount > 0 ? '${spot.fishCount} peixe(s)' : '–'),
            _DetailRow(
                label: 'Coordenadas',
                value: '${spot.lat.toStringAsFixed(5)}, ${spot.lng.toStringAsFixed(5)}'),
            const SizedBox(height: 20),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _kGold,
                    side: const BorderSide(color: _kGold),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Editar'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _editSpot(spot);
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red.shade400,
                    side: BorderSide(color: Colors.red.shade400),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Excluir'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _deleteSpot(spot);
                  },
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteSpot(FishingSpot spot) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _kPanel,
        title: const Text('Excluir ponto?', style: TextStyle(color: _kGold)),
        content: Text(
          'O ponto "${spot.description.isNotEmpty ? spot.description : 'Ponto de Pesca'}" será removido permanentemente.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar', style: TextStyle(color: _kGoldDim)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Excluir', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final spots = await _spotService.delete(spot.id);
      if (mounted) setState(() => _spots = spots);
    }
  }

  Future<void> _editSpot(FishingSpot spot) async {
    final result = await showModalBottomSheet<FishingSpot?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _kPanel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _EditSpotSheet(spot: spot),
    );
    if (result != null) {
      final spots = await _spotService.update(result);
      if (mounted) setState(() => _spots = spots);
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _fmtDate(DateTime dt) {
    return '${dt.day.toString().padLeft(2, '0')}/'
        '${dt.month.toString().padLeft(2, '0')}/'
        '${dt.year}  '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }

  List<Marker> _buildMarkers(LatLng pos, Telemetry? tel) {
    final markers = <Marker>[];

    // Barco
    markers.add(Marker(
      point: pos,
      width: 48,
      height: 48,
      child: Transform.rotate(
        angle: (tel?.heading ?? 0) * math.pi / 180,
        child: Image.asset('assets/boat_icon.png', fit: BoxFit.contain),
      ),
    ));

    // Âncora
    if (_anchorPoint != null) {
      markers.add(Marker(
        point: _anchorPoint!,
        width: 40,
        height: 40,
        child: const Icon(Icons.anchor, color: Colors.red, size: 36),
      ));
    }

    // Pontos de pesca
    for (final spot in _spots) {
      markers.add(Marker(
        point: LatLng(spot.lat, spot.lng),
        width: 48,
        height: 48,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _showSpotDetail(spot),
          child: Image.asset('assets/fish_point.png', fit: BoxFit.contain),
        ),
      ));
    }

    return markers;
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final tel = widget.tel;
    final pos = (tel != null && tel.hasValidPosition)
        ? LatLng(tel.lat, tel.lon)
        : const LatLng(-15.0, -47.0);

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: pos,
            initialZoom: 17.0,
            onMapReady: () => setState(() => _mapReady = true),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.modulobarco.barco_app',
            ),
            MarkerLayer(markers: _buildMarkers(pos, tel)),
            Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: _TelemetryCard(tel: tel),
              ),
            ),
          ],
        ),

        // FABs
        Positioned(
          right: 16,
          bottom: 24 + MediaQuery.of(context).padding.bottom,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Lista de pontos
              FloatingActionButton.small(
                heroTag: 'fab_list',
                onPressed: _showSpotsList,
                backgroundColor: Colors.teal.shade700,
                foregroundColor: Colors.white,
                tooltip: 'Ver pontos de pesca',
                child: const Icon(Icons.format_list_bulleted),
              ),
              const SizedBox(height: 10),
              // Adicionar ponto
              FloatingActionButton(
                heroTag: 'fab_add',
                onPressed: _addSpot,
                backgroundColor: Colors.teal.shade800,
                foregroundColor: Colors.white,
                tooltip: 'Salvar ponto de pesca',
                child: const Icon(Icons.add_location_alt),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Add spot bottom sheet ─────────────────────────────────────────────────────

class _AddSpotSheet extends StatefulWidget {
  final double lat;
  final double lng;
  const _AddSpotSheet({required this.lat, required this.lng});

  @override
  State<_AddSpotSheet> createState() => _AddSpotSheetState();
}

class _AddSpotSheetState extends State<_AddSpotSheet> {
  final _descCtrl    = TextEditingController();
  final _speciesCtrl = TextEditingController();
  final _countCtrl   = TextEditingController();

  @override
  void dispose() {
    _descCtrl.dispose();
    _speciesCtrl.dispose();
    _countCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final spot = FishingSpot(
      id:          DateTime.now().millisecondsSinceEpoch.toString(),
      lat:         widget.lat,
      lng:         widget.lng,
      dateTime:    DateTime.now(),
      description: _descCtrl.text.trim(),
      fishCount:   int.tryParse(_countCtrl.text.trim()) ?? 0,
      fishSpecies: _speciesCtrl.text.trim(),
    );
    Navigator.pop(context, spot);
  }

  InputDecoration _inputDec(String label) => InputDecoration(
    labelText: label,
    labelStyle: const TextStyle(color: Colors.white54),
    filled: true,
    fillColor: Colors.white.withValues(alpha: 0.05),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: _kGoldDim.withValues(alpha: 0.5)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: _kGold),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20, right: 20, top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40, height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const Center(
            child: Text('Novo Ponto de Pesca',
                style: TextStyle(color: _kGold, fontSize: 17,
                    fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              '${widget.lat.toStringAsFixed(5)}, ${widget.lng.toStringAsFixed(5)}',
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _descCtrl,
            style: const TextStyle(color: Colors.white),
            decoration: _inputDec('Descrição (ex: Baía da pedra grande)'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _speciesCtrl,
            style: const TextStyle(color: Colors.white),
            decoration: _inputDec('Espécie (ex: Tucunaré)'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _countCtrl,
            style: const TextStyle(color: Colors.white),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: _inputDec('Quantidade de peixes'),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: _kGold,
                foregroundColor: _kDark,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              icon: const Icon(Icons.save_outlined),
              label: const Text('Salvar Ponto',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              onPressed: _save,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Edit spot bottom sheet ────────────────────────────────────────────────────

class _EditSpotSheet extends StatefulWidget {
  final FishingSpot spot;
  const _EditSpotSheet({required this.spot});

  @override
  State<_EditSpotSheet> createState() => _EditSpotSheetState();
}

class _EditSpotSheetState extends State<_EditSpotSheet> {
  late final TextEditingController _descCtrl;
  late final TextEditingController _speciesCtrl;
  late final TextEditingController _countCtrl;

  @override
  void initState() {
    super.initState();
    _descCtrl    = TextEditingController(text: widget.spot.description);
    _speciesCtrl = TextEditingController(text: widget.spot.fishSpecies);
    _countCtrl   = TextEditingController(
        text: widget.spot.fishCount > 0 ? '${widget.spot.fishCount}' : '');
  }

  @override
  void dispose() {
    _descCtrl.dispose();
    _speciesCtrl.dispose();
    _countCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final updated = FishingSpot(
      id:          widget.spot.id,
      lat:         widget.spot.lat,
      lng:         widget.spot.lng,
      dateTime:    widget.spot.dateTime,
      description: _descCtrl.text.trim(),
      fishCount:   int.tryParse(_countCtrl.text.trim()) ?? 0,
      fishSpecies: _speciesCtrl.text.trim(),
    );
    Navigator.pop(context, updated);
  }

  InputDecoration _inputDec(String label) => InputDecoration(
    labelText: label,
    labelStyle: const TextStyle(color: Colors.white54),
    filled: true,
    fillColor: Colors.white.withValues(alpha: 0.05),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: _kGoldDim.withValues(alpha: 0.5)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: _kGold),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20, right: 20, top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(
            child: Container(
              width: 40, height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const Center(
            child: Text('Editar Ponto de Pesca',
                style: TextStyle(color: _kGold, fontSize: 17,
                    fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _descCtrl,
            style: const TextStyle(color: Colors.white),
            decoration: _inputDec('Descrição'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _speciesCtrl,
            style: const TextStyle(color: Colors.white),
            decoration: _inputDec('Espécie'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _countCtrl,
            style: const TextStyle(color: Colors.white),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: _inputDec('Quantidade de peixes'),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: _kGold,
                foregroundColor: _kDark,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              icon: const Icon(Icons.save_outlined),
              label: const Text('Salvar Alterações',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              onPressed: _save,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Detail row ────────────────────────────────────────────────────────────────

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 100,
          child: Text(label,
              style: const TextStyle(color: Colors.white38, fontSize: 12)),
        ),
        Expanded(
          child: Text(value,
              style: const TextStyle(color: Colors.white70, fontSize: 13)),
        ),
      ],
    ),
  );
}

// ── Telemetry overlay ─────────────────────────────────────────────────────────

class _TelemetryCard extends StatelessWidget {
  final Telemetry? tel;
  const _TelemetryCard({required this.tel});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.62),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: Colors.white12),
    ),
    child: Row(children: [
      Expanded(child: _Item(icon: Icons.speed,      label: 'Velocidade',
          value: tel == null ? '--' : '${tel!.speedKmh.toStringAsFixed(1)} km/h')),
      _Div(),
      Expanded(child: _Item(icon: Icons.straighten, label: 'Dist. âncora',
          value: (tel == null || !tel!.anchorActive) ? '--' : '${tel!.distToAnchor.toStringAsFixed(1)} m')),
      _Div(),
      Expanded(child: _Item(icon: Icons.explore,    label: 'Heading',
          value: tel == null ? '--' : '${tel!.heading.toStringAsFixed(0)}°')),
      _Div(),
      Expanded(child: _Item(icon: Icons.anchor,     label: 'Dir. âncora',
          value: (tel == null || !tel!.anchorActive) ? '--' : '${tel!.bearingToAnchor.toStringAsFixed(0)}°')),
    ]),
  );
}

class _Item extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _Item({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, color: Colors.white70, size: 16),
      const SizedBox(height: 2),
      Text(value, style: const TextStyle(color: Colors.white, fontSize: 14,
          fontWeight: FontWeight.bold)),
      Text(label, style: const TextStyle(color: Colors.white54, fontSize: 9)),
    ],
  );
}

class _Div extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
    width: 1, height: 36, color: Colors.white12,
    margin: const EdgeInsets.symmetric(horizontal: 4),
  );
}
