class FishingSpot {
  final String id;
  final double lat;
  final double lng;
  final DateTime dateTime;
  final String description;
  final int fishCount;
  final String fishSpecies;

  const FishingSpot({
    required this.id,
    required this.lat,
    required this.lng,
    required this.dateTime,
    required this.description,
    required this.fishCount,
    required this.fishSpecies,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'lat': lat,
    'lng': lng,
    'dateTime': dateTime.toIso8601String(),
    'description': description,
    'fishCount': fishCount,
    'fishSpecies': fishSpecies,
  };

  factory FishingSpot.fromJson(Map<String, dynamic> j) => FishingSpot(
    id:          j['id'] as String,
    lat:         (j['lat'] as num).toDouble(),
    lng:         (j['lng'] as num).toDouble(),
    dateTime:    DateTime.parse(j['dateTime'] as String),
    description: j['description'] as String,
    fishCount:   j['fishCount'] as int,
    fishSpecies: j['fishSpecies'] as String,
  );
}
