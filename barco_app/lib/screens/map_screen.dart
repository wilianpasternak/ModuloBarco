import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../models/telemetry.dart';
import '../services/ble_service.dart';

class MapScreen extends StatefulWidget {
  final BleService ble;
  final Telemetry? tel;
  const MapScreen({super.key, required this.ble, this.tel});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();
  LatLng? _anchorPoint;
  bool _mapReady = false;
  LatLng? _lastMovedTo;

  @override
  void didUpdateWidget(MapScreen old) {
    super.didUpdateWidget(old);
    final tel = widget.tel;
    if (tel == null) return;

    // Salva ponto ancora quando ativado
    if (tel.anchorActive && _anchorPoint == null) {
      _anchorPoint = LatLng(tel.lat, tel.lon);
    }
    if (!tel.anchorActive) _anchorPoint = null;

    // Move mapa para posicao do barco
    if (_mapReady && tel.hasValidPosition) {
      final pos = LatLng(tel.lat, tel.lon);
      if (_lastMovedTo == null ||
          (pos.latitude - _lastMovedTo!.latitude).abs() > 0.000005 ||
          (pos.longitude - _lastMovedTo!.longitude).abs() > 0.000005) {
        _mapController.move(pos, _mapController.camera.zoom);
        _lastMovedTo = pos;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tel = widget.tel;
    final pos = (tel != null && tel.hasValidPosition)
        ? LatLng(tel.lat, tel.lon)
        : const LatLng(-15.0, -47.0);

    return FlutterMap(
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
        // Overlay de telemetria
        Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: _TelemetryCard(tel: tel),
          ),
        ),
      ],
    );
  }

  List<Marker> _buildMarkers(LatLng pos, Telemetry? tel) {
    final markers = <Marker>[];
    markers.add(Marker(
      point: pos,
      width: 48,
      height: 48,
      child: Transform.rotate(
        angle: (tel?.heading ?? 0) * math.pi / 180,
        child: const Icon(Icons.navigation, color: Colors.blue, size: 40),
      ),
    ));
    if (_anchorPoint != null) {
      markers.add(Marker(
        point: _anchorPoint!,
        width: 40,
        height: 40,
        child: const Icon(Icons.anchor, color: Colors.red, size: 36),
      ));
    }
    return markers;
  }
}

// ── Telemetry overlay ────────────────────────────────────────────────────────
class _TelemetryCard extends StatelessWidget {
  final Telemetry? tel;
  const _TelemetryCard({required this.tel});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(children: [
        Expanded(child: _Item(icon: Icons.speed,      label: 'Velocidade',   value: tel == null ? '--' : '${tel!.speedKmh.toStringAsFixed(1)} km/h')),
        _Div(),
        Expanded(child: _Item(icon: Icons.straighten, label: 'Dist. âncora', value: (tel == null || !tel!.anchorActive) ? '--' : '${tel!.distToAnchor.toStringAsFixed(1)} m')),
        _Div(),
        Expanded(child: _Item(icon: Icons.explore,    label: 'Heading',      value: tel == null ? '--' : '${tel!.heading.toStringAsFixed(0)}°')),
        _Div(),
        Expanded(child: _Item(icon: Icons.anchor,     label: 'Dir. âncora',  value: (tel == null || !tel!.anchorActive) ? '--' : '${tel!.bearingToAnchor.toStringAsFixed(0)}°')),
      ]),
    );
  }
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
      Text(value, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
      Text(label, style: const TextStyle(color: Colors.white54, fontSize: 9)),
    ],
  );
}

class _Div extends StatelessWidget {
  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: 36, color: Colors.white12, margin: const EdgeInsets.symmetric(horizontal: 4));
}
