import 'package:flutter/material.dart';

import '../../game/data/game_models.dart' as am_game;
import 'map_session_models.dart';

class MapFloatingControls extends StatelessWidget {
  const MapFloatingControls({
    super.key,
    required this.followMe,
    required this.onFollowPressed,
    required this.onFitPressed,
    this.bottomOffset = 280,
  });

  final bool followMe;
  final VoidCallback onFollowPressed;
  final VoidCallback onFitPressed;
  final double bottomOffset;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 16,
      bottom: bottomOffset,
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
    this.bottomActionOffset = 290,
    this.showTopStatus = true,
  });

  final MapSessionState mapState;
  final am_game.AmongUsGameState amongUsState;
  final Set<String> activeModules;
  final String? authUserId;
  final VoidCallback onKillAction;
  final VoidCallback onOpenVote;
  final VoidCallback onCloseFinished;
  final double bottomActionOffset;
  final bool showTopStatus;

  @override
  Widget build(BuildContext context) {
    final winnerId = mapState.gameState.winnerId;
    final winnerName = winnerId != null
        ? (mapState.members[winnerId]?.nickname ?? winnerId)
        : '-';
    final isInProgress = mapState.gameState.status == 'in_progress';
    final canUseKill = activeModules.contains('proximity') &&
        mapState.proximateTargetId != null &&
        !mapState.isEliminated &&
        isInProgress;
    final canOpenVote = activeModules.contains('round') &&
        activeModules.contains('vote') &&
        mapState.myRole == 'host' &&
        isInProgress;
    final canShowMissionButton =
        activeModules.contains('mission') && isInProgress;

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
                    Expanded(
                      child: Text(
                        'SOS 알림을 받았습니다.',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (showTopStatus && isInProgress && mapState.gameState.aliveCount > 0)
          Positioned(
            top: MediaQuery.of(context).padding.top + 78,
            right: 16,
            child: _OverlayChip(
              icon: Icons.person,
              label: '생존 ${mapState.gameState.aliveCount}명',
            ),
          ),
        if (showTopStatus &&
            activeModules.contains('tag') &&
            isInProgress &&
            mapState.gameState.taggerId != null)
          Positioned(
            top: MediaQuery.of(context).padding.top + 78,
            left: 16,
            child: _OverlayChip(
              icon: Icons.directions_run,
              label: mapState.gameState.taggerId == authUserId ? '술래' : '추격 중',
              accentColor: mapState.gameState.taggerId == authUserId
                  ? Colors.redAccent
                  : Colors.white,
            ),
          ),
        if (canUseKill)
          Positioned(
            left: 16,
            right: 16,
            bottom: bottomActionOffset,
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
        if (activeModules.contains('round') && activeModules.contains('vote'))
          Positioned(
            bottom: bottomActionOffset,
            right: 16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _OverlayChip(
                  icon: Icons.change_circle_outlined,
                  label: '라운드 ${mapState.gameState.roundNumber ?? 0}',
                ),
                if (canOpenVote) ...[
                  const SizedBox(height: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF7C3AED),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
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
        if (canShowMissionButton)
          Positioned(
            bottom: bottomActionOffset,
            right: 16,
            child: Stack(
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
          ),
        if (mapState.isEliminated)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.75),
              child: const Center(
                child: Text(
                  '탈락!\n당신은 제거되었습니다.',
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
              color: Colors.black.withValues(alpha: 0.8),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (winnerId != null && winnerId == authUserId) ...[
                      const Text(
                        '승리!',
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
      ],
    );
  }
}

class _OverlayChip extends StatelessWidget {
  const _OverlayChip({
    required this.icon,
    required this.label,
    this.accentColor = Colors.white,
  });

  final IconData icon;
  final String label;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: accentColor, size: 18),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: accentColor,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
