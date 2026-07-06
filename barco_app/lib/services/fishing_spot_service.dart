import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/fishing_spot.dart';

class FishingSpotService {
  static const _key = 'fishing_spots_v1';

  Future<List<FishingSpot>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list.map((e) => FishingSpot.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> _persist(List<FishingSpot> spots) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(spots.map((e) => e.toJson()).toList()));
  }

  Future<List<FishingSpot>> add(FishingSpot spot) async {
    final spots = await load();
    spots.add(spot);
    await _persist(spots);
    return spots;
  }

  Future<List<FishingSpot>> delete(String id) async {
    final spots = await load();
    spots.removeWhere((s) => s.id == id);
    await _persist(spots);
    return spots;
  }
}
