import 'package:flutter/material.dart';

import '../../game/data/game_models.dart' as am_game;
import 'map_session_models.dart';

class MapFloatingControls extends StatelessWidget {
  const MapFloatingControls({
    super.key,
    required this.followMe,
    required this.onFollowPressed,
    required this.onFitPressed,
  });

  final bool followMe;
  final VoidCallback onFollowPressed;
  final VoidCallback onFitPressed;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 16,
      bottom: 280,
      child: Column(
        children: [
          FloatingActionButton.small(
            heroTag: 'follow',
            onPressed: onFollowPressed,
            backgroundColor: followMe ? const Color(0xFF2196F3) : Colors.white,
            foregroundColor: followMe ? Colors.white : Colors.black54,
            child: const Icon(Icons.my_location),
          ),
          const SizedBox(height: 8),
          FloatingActionButton.small(
            heroTag: 'fit',
            onPressed: onFitPressed,
            backgroundColor: Colors.white,
            foregroundColor: Colors.black54,
            child: const Icon(Icons.zoom_out_map),
          ),
        ],
      ),
    );
  }
}

class MapOverlayLayer extends StatelessWidget {
  const MapOverlayLayer({
    super.key,
    required this.mapState,
    required this.amongUsState,
    required this.activeModules,
    required this.authUserId,
    required this.onKillAction,
    required this.onOpenVote,
    required this.onCloseFinished,
    required this.onSendEmergency,
  });

  final MapSessionState mapState;
  final am_game.AmongUsGameState amongUsState;
  final Set<String> activeModules;
  final String? authUserId;
  final VoidCallback onKillAction;
  final VoidCallback onOpenVote;
  final VoidCallback onCloseFinished;
  final VoidCallback onSendEmergency;

  @override
  Widget build(BuildContext context) {
    final winnerId = mapState.gameState.winnerId;
    final winnerName =
        winnerId != null ? (mapState.members[winnerId]?.nickname ?? winnerId) : '-';

    return Stack(
      children: [
        if (mapState.sosTriggered)
          Positioned(
            top: MediaQuery.of(context).padding.top + 72,
            left: 16,
            right: 16,
            child: Material(
              borderRadius: BorderRadius.circular(12),
              color: Colors.red,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber, color: Colors.white),
                    SizedBox(width: 8),
                    Text(
                      'SOS 알림을 받았습니다!',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (activeModules.contains('proximity') &&
            mapState.proximateTargetId != null &&
            !mapState.isEliminated &&
            mapState.gameState.status == 'in_progress')
          Positioned(
            bottom: 280,
            left: 0,
            right: 0,
            child: Center(
              child: FloatingActionButton.extended(
                heroTag: 'kill',
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                icon: Icon(
                  activeModules.contains('tag')
                      ? Icons.touch_app
                      : Icons.dangerous,
                ),
                label: Text(
                  activeModules.contains('tag') ? '태그' : '제거',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                onPressed: onKillAction,
              ),
            ),
          ),
        if (mapState.gameState.status == 'in_progress')
          Positioned(
            top: 80,
            right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.person, color: Colors.white, size: 18),
                  const SizedBox(width: 4),
                  Text(
                    '생존 ${mapState.gameState.aliveCount}명',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (activeModules.contains('tag') &&
            mapState.gameState.status == 'in_progress')
          Positioned(
            top: 80,
            left: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.directions_run,
                    color: mapState.gameState.taggerId == authUserId
                        ? Colors.red
                        : Colors.grey[400],
                    size: 24,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    mapState.gameState.taggerId == authUserId ? '술래' : '도망자',
                    style: TextStyle(
                      color: mapState.gameState.taggerId == authUserId
                          ? Colors.red
                          : Colors.grey[300],
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (activeModules.contains('round') && activeModules.contains('vote'))
          Positioned(
            bottom: 290,
            right: 16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '라운드 ${mapState.gameState.roundNumber ?? 0}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (mapState.myRole == 'host') ...[
                  const SizedBox(height: 6),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF7C3AED),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      textStyle: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    onPressed: onOpenVote,
                    child: const Text('투표 시작'),
                  ),
                ],
              ],
            ),
          ),
        if (activeModules.contains('mission'))
          Positioned(
            bottom: 290,
            right: 16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        textStyle: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      icon: const Icon(Icons.explore, size: 18),
                      label: const Text('미션 보기'),
                      onPressed: () {},
                    ),
                    if ((mapState.gameState.incompleteMissionCount ?? 0) > 0)
                      Positioned(
                        top: -6,
                        right: -6,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            '${mapState.gameState.incompleteMissionCount}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        if (mapState.isEliminated)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.75),
              child: const Center(
                child: Text(
                  '탈락!\n당신은 제거되었습니다',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ),
        if (mapState.gameState.status == 'finished')
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.80),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (winnerId != null && winnerId == authUserId) ...[
                      const Text(
                        '우승!',
                        style: TextStyle(
                          color: Color(0xFFFFD700),
                          fontSize: 48,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'You Won',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                        ),
                      ),
                    ] else ...[
                      const Text(
                        '게임 종료',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 36,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        winnerName,
                        style: const TextStyle(
                          color: Color(0xFFFFD700),
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                    const SizedBox(height: 32),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black87,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 40,
                          vertical: 14,
                        ),
                        textStyle: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      onPressed: onCloseFinished,
                      child: const Text('나가기'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (amongUsState.myRole != null)
          Positioned(
            top: 50,
            right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: amongUsState.myRole!.isImpostor
                    ? Colors.red.withValues(alpha: 0.9)
                    : Colors.green.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                amongUsState.myRole!.isImpostor ? '😈 임포스터' : '👨‍🚀 크루원',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ),
          ),
        if (amongUsState.isStarted && amongUsState.isAlive)
          Positioned(
            bottom: 120,
            left: 16,
            child: FloatingActionButton.extended(
              heroTag: 'emergency',
              backgroundColor: Colors.orange,
              onPressed: onSendEmergency,
              icon: const Icon(Icons.warning_amber, color: Colors.white),
              label: const Text(
                '긴급 회의',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        if (amongUsState.myRole?.isImpostor == true && amongUsState.isAlive)
          Positioned(
            bottom: 120,
            right: 16,
            child: FloatingActionButton.extended(
              heroTag: 'kill_impostor',
              backgroundColor: Colors.red,
              onPressed: () {},
              icon: const Icon(Icons.close, color: Colors.white),
              label: const Text(
                '킬',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
