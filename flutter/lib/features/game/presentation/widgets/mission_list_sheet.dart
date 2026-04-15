// lib/features/game/presentation/widgets/mission_list_sheet.dart
//
// GameProvider의 미션 목록을 보여주는 바텀 시트

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/game_models.dart';
import '../../providers/game_provider.dart';

class MissionListSheet extends ConsumerWidget {
  const MissionListSheet({
    super.key,
    required this.sessionId,
  });

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final missions = ref.watch(gameProvider(sessionId)).myMissions;

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1A1535),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 드래그 핸들
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            '내 미션',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          if (missions.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  '배정된 미션이 없습니다.',
                  style: TextStyle(color: Colors.white54, fontSize: 14),
                ),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: missions.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final mission = missions[index];
                return _MissionTile(mission: mission);
              },
            ),
        ],
      ),
    );
  }
}

class _MissionTile extends StatelessWidget {
  const _MissionTile({required this.mission});

  final Mission mission;

  @override
  Widget build(BuildContext context) {
    final statusLabel = switch (mission.status) {
      MissionStatus.locked    => '잠김',
      MissionStatus.ready     => '수행 가능',
      MissionStatus.completed => '완료',
    };

    final typeLabel = switch (mission.type) {
      MissionType.qr       => 'QR 스캔',
      MissionType.location => '위치',
    };

    final statusColor = switch (mission.status) {
      MissionStatus.locked    => Colors.white38,
      MissionStatus.ready     => const Color(0xFF22C55E),
      MissionStatus.completed => const Color(0xFF60A5FA),
    };

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: mission.status == MissionStatus.ready
              ? const Color(0xFF22C55E).withValues(alpha: 0.5)
              : Colors.transparent,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        typeLabel,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        mission.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  mission.description,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            statusLabel,
            style: TextStyle(
              color: statusColor,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
