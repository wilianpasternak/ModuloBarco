class Telemetry {
  final double lat;
  final double lon;
  final double heading;
  final double speedKmh;
  final double distToAnchor;
  final double bearingToAnchor;
  final bool anchorActive;
  final int pwm;
  final bool northActive;
  final bool motorLigado;
  final int satellites;

  const Telemetry({
    required this.lat,
    required this.lon,
    required this.heading,
    required this.speedKmh,
    required this.distToAnchor,
    required this.bearingToAnchor,
    required this.anchorActive,
    required this.pwm,
    required this.northActive,
    required this.motorLigado,
    required this.satellites,
  });

  bool get gpsFix => satellites >= 4;
  bool get hasValidPosition => lat != 0.0 || lon != 0.0;

  // Format: $lat,lon,hdg,spd,dist,brg,anc,pwm,nrt,mot,sat\n
  static Telemetry? fromLine(String line) {
    if (!line.startsWith('\$')) return null;
    final parts = line.substring(1).split(',');
    if (parts.length < 7) return null;
    try {
      return Telemetry(
        lat:             double.parse(parts[0]),
        lon:             double.parse(parts[1]),
        heading:         double.parse(parts[2]),
        speedKmh:        double.parse(parts[3]),
        distToAnchor:    double.parse(parts[4]),
        bearingToAnchor: double.parse(parts[5]),
        anchorActive:    parts[6].trim() == '1',
        pwm:             parts.length > 7 ? int.tryParse(parts[7].trim()) ?? 0 : 0,
        northActive:     parts.length > 8 ? parts[8].trim() == '1' : false,
        motorLigado:     parts.length > 9 ? parts[9].trim() == '1' : false,
        satellites:      parts.length > 10 ? int.tryParse(parts[10].trim()) ?? 0 : 0,
      );
    } catch (_) {
      return null;
    }
  }
}
