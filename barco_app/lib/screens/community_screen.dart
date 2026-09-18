import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/community_data.dart';

const _kGold    = Color(0xFFD4A800);
const _kGoldDim = Color(0xFF6B5400);
const _kDark    = Color(0xFF0F0F08);
const _kPanel   = Color(0xFF1A1A10);

final _dateFmt = DateFormat('dd/MM/yyyy');

class CommunityScreen extends StatelessWidget {
  const CommunityScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          Container(
            color: _kPanel,
            child: const TabBar(
              indicatorColor: _kGold,
              labelColor: _kGold,
              unselectedLabelColor: _kGoldDim,
              tabs: [
                Tab(text: 'Feed'),
                Tab(text: 'Ranking'),
                Tab(text: 'Torneios'),
              ],
            ),
          ),
          const Expanded(
            child: TabBarView(
              children: [
                _FeedTab(),
                _RankingTab(),
                _TorneiosTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FeedTab extends StatelessWidget {
  const _FeedTab();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _kDark,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: mockPosts.length,
        itemBuilder: (context, index) {
          final post = mockPosts[index];
          return Container(
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _kPanel,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _kGoldDim.withValues(alpha: 0.4)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: post.photoColor,
                  child: Icon(post.photoIcon, color: Colors.white, size: 28),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(post.anglerName,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text(_dateFmt.format(post.date),
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 12)),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          const Icon(Icons.favorite, color: Colors.redAccent, size: 18),
                          const SizedBox(width: 6),
                          Text('${post.likes} curtidas',
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 13)),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _RankingTab extends StatelessWidget {
  const _RankingTab();

  @override
  Widget build(BuildContext context) {
    final sorted = [...mockRanking]
      ..sort((a, b) => b.fishSizeCm.compareTo(a.fishSizeCm));
    return Container(
      color: _kDark,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: sorted.length,
        itemBuilder: (context, index) {
          final entry = sorted[index];
          return Container(
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _kPanel,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _kGoldDim.withValues(alpha: 0.4)),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: _kGoldDim,
                  child: Text('${index + 1}º',
                      style: const TextStyle(
                          color: _kGold, fontWeight: FontWeight.bold, fontSize: 13)),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(entry.anglerName,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text('${entry.fishType} • ${_dateFmt.format(entry.date)}',
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 12)),
                    ],
                  ),
                ),
                Text('${entry.fishSizeCm.toStringAsFixed(1)} cm',
                    style: const TextStyle(
                        color: _kGold, fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _TorneiosTab extends StatelessWidget {
  const _TorneiosTab();

  Color _statusColor(String status) {
    switch (status) {
      case 'Inscrições abertas':
        return Colors.green.shade400;
      case 'Em breve':
        return Colors.orange.shade400;
      default:
        return Colors.white38;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _kDark,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: mockTournaments.length,
        itemBuilder: (context, index) {
          final t = mockTournaments[index];
          return Container(
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _kPanel,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _kGoldDim.withValues(alpha: 0.4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.emoji_events, color: _kGold, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(t.name,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Icon(Icons.calendar_today, color: Colors.white38, size: 14),
                    const SizedBox(width: 6),
                    Text(_dateFmt.format(t.date),
                        style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(Icons.location_on, color: Colors.white38, size: 14),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(t.location,
                          style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _statusColor(t.status).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _statusColor(t.status)),
                  ),
                  child: Text(t.status,
                      style: TextStyle(
                          color: _statusColor(t.status),
                          fontSize: 11,
                          fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
