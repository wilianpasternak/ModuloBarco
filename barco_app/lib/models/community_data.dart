import 'package:flutter/material.dart';

class CommunityPost {
  final String anglerName;
  final DateTime date;
  final int likes;
  final IconData photoIcon;
  final Color photoColor;
  const CommunityPost({
    required this.anglerName,
    required this.date,
    required this.likes,
    required this.photoIcon,
    required this.photoColor,
  });
}

class RankingEntry {
  final String anglerName;
  final String fishType;
  final double fishSizeCm;
  final DateTime date;
  const RankingEntry({
    required this.anglerName,
    required this.fishType,
    required this.fishSizeCm,
    required this.date,
  });
}

class Tournament {
  final String name;
  final DateTime date;
  final String location;
  final String status;
  const Tournament({
    required this.name,
    required this.date,
    required this.location,
    required this.status,
  });
}

final mockPosts = <CommunityPost>[
  CommunityPost(
    anglerName: 'João Pereira',
    date: DateTime(2026, 9, 12),
    likes: 34,
    photoIcon: Icons.set_meal,
    photoColor: Colors.teal.shade700,
  ),
  CommunityPost(
    anglerName: 'Marcos Silva',
    date: DateTime(2026, 9, 10),
    likes: 21,
    photoIcon: Icons.phishing,
    photoColor: Colors.indigo.shade700,
  ),
  CommunityPost(
    anglerName: 'Rafael Souza',
    date: DateTime(2026, 9, 8),
    likes: 57,
    photoIcon: Icons.water,
    photoColor: Colors.blue.shade700,
  ),
  CommunityPost(
    anglerName: 'Carlos Eduardo',
    date: DateTime(2026, 9, 3),
    likes: 12,
    photoIcon: Icons.anchor,
    photoColor: Colors.brown.shade600,
  ),
  CommunityPost(
    anglerName: 'Bruno Alves',
    date: DateTime(2026, 8, 29),
    likes: 8,
    photoIcon: Icons.directions_boat,
    photoColor: Colors.orange.shade800,
  ),
];

final mockRanking = <RankingEntry>[
  RankingEntry(
    anglerName: 'Rafael Souza',
    fishType: 'Tucunaré',
    fishSizeCm: 58.0,
    date: DateTime(2026, 9, 8),
  ),
  RankingEntry(
    anglerName: 'João Pereira',
    fishType: 'Dourado',
    fishSizeCm: 52.5,
    date: DateTime(2026, 9, 12),
  ),
  RankingEntry(
    anglerName: 'Marcos Silva',
    fishType: 'Pintado',
    fishSizeCm: 47.0,
    date: DateTime(2026, 9, 10),
  ),
  RankingEntry(
    anglerName: 'Bruno Alves',
    fishType: 'Traíra',
    fishSizeCm: 39.5,
    date: DateTime(2026, 8, 29),
  ),
  RankingEntry(
    anglerName: 'Carlos Eduardo',
    fishType: 'Lambari',
    fishSizeCm: 18.0,
    date: DateTime(2026, 9, 3),
  ),
];

final mockTournaments = <Tournament>[
  Tournament(
    name: 'Torneio de Verão Pesca Plus',
    date: DateTime(2026, 12, 5),
    location: 'Represa de Ibitinga - SP',
    status: 'Inscrições abertas',
  ),
  Tournament(
    name: 'Copa Tucunaré Gigante',
    date: DateTime(2026, 10, 18),
    location: 'Rio Araguaia - GO',
    status: 'Inscrições abertas',
  ),
  Tournament(
    name: 'Desafio Pesque e Solte',
    date: DateTime(2026, 9, 27),
    location: 'Represa de Três Irmãos - SP',
    status: 'Em breve',
  ),
  Tournament(
    name: 'Torneio Amigos da Pescaria',
    date: DateTime(2026, 7, 14),
    location: 'Represa de Barra Bonita - SP',
    status: 'Encerrado',
  ),
];
