import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../game/data/game_models.dart' as am_game;
import '../../game/presentation/game_meeting_screen.dart';
import '../../game/presentation/minigames/minigame_wrapper_screen.dart';
import '../../game/presentation/qr_scanner_screen.dart';
import '../../game/presentation/widgets/mission_list_sheet.dart';
import '../../game/providers/game_provider.dart';
import '../../../core/services/socket_service.dart';
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
    this.onVerbalKill,
    this.onShowMission,
    this.bottomActionOffset = 290,
    this.showTopStatus = true,
    this.sessionId,
  });

  final MapSessionState mapState;
  final am_game.AmongUsGameState amongUsState;
  final Set<String> activeModules;
  final String? authUserId;
  final VoidCallback onKillAction;
  final VoidCallback onOpenVote;
  final VoidCallback? onShowMission;
  final VoidCallback? onVerbalKill;
  final VoidCallback onCloseFinished;
  final double bottomActionOffset;
  final bool showTopStatus;

  /// 세션 ID – 미션 시트 / QR 스캐너에서 Provider 참조에 사용합니다.
  final String? sessionId;

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
    // verbal 모드(round+vote)에서는 전원이 긴급호출 가능
    final canOpenVote = activeModules.contains('round') &&
        activeModules.contains('vote') &&
        !mapState.isEliminated &&
        isInProgress;
    final isVerbalMode = activeModules.contains('vote') &&
        activeModules.contains('round') &&
        !activeModules.contains('proximity');
    // verbal 모드 임포스터 킬 버튼
    final isImpostor = amongUsState.myRole?.isImpostor == true;
    final showVerbalKillButton =
        isVerbalMode && isImpostor && !mapState.isEliminated && isInProgress;
    final verbalKillHasTarget = mapState.proximateTargetId != null;
    final canShowMissionButton =
        activeModules.contains('mission') && isInProgress;

    // ready 상태인 위치 기반 미션 목록
    final readyLocationMissions = amongUsState.myMissions
        .where((m) =>
            m.type == am_game.MissionType.location &&
            m.status == am_game.MissionStatus.ready)
        .toList();

    return Stack(
      children: [
        // ── 회의 시작 이벤트 → GameMeetingScreen 자동 이동 ─────────────────
        if (isInProgress && sessionId != null)
          Consumer(
            builder: (ctx, ref, _) {
              ref.listen(
                gameProvider(sessionId!).select(
                  (s) => s.shouldNavigateToMeeting,
                ),
                (_, shouldNavigate) {
                  if (!shouldNavigate) return;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!ctx.mounted) return;
                    final memberNames = mapState.members.map(
                      (k, v) => MapEntry(k, v.nickname),
                    );
                    Navigator.of(ctx).push(
                      MaterialPageRoute(
                        builder: (_) => GameMeetingScreen(
                          sessionId: sessionId!,
                          memberNames: memberNames,
                          myUserId: authUserId ?? '',
                        ),
                      ),
                    );
                    ref
                        .read(gameProvider(sessionId!).notifier)
                        .resetMeetingNavigation();
                  });
                },
              );
              return const SizedBox.shrink();
            },
          ),

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
        // ── 우측 상단: 미션 보기 / QR 스캔 버튼 ─────────────────────────────────
        if (isInProgress && sessionId != null)
          Positioned(
            top: MediaQuery.of(context).padding.top + 126,
            right: 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                GestureDetector(
                  onTap: () {
                    showModalBottomSheet<void>(
                      context: context,
                      backgroundColor: Colors.transparent,
                      isScrollControlled: true,
                      builder: (_) => MissionListSheet(sessionId: sessionId!),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F766E).withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      '미션 보기',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            QrScannerScreen(sessionId: sessionId!),
                      ),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF7C3AED).withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      'QR 스캔',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        // ── 중앙 하단: 위치 기반 미션 수행 버튼 (사보타지 상태 분기) ───────────────
        if (isInProgress &&
            readyLocationMissions.isNotEmpty &&
            sessionId != null)
          Positioned(
            bottom: bottomActionOffset + 56,
            left: 32,
            right: 32,
            child: Center(
              child: Builder(
                builder: (ctx) {
                  final mission = readyLocationMissions.first;
                  final isSabotaged = mission.isSabotaged;
                  return GestureDetector(
                    onTap: () => Navigator.of(ctx).push(
                      MaterialPageRoute(
                        builder: (_) => MinigameWrapperScreen(
                          sessionId: sessionId!,
                          mission: mission,
                        ),
                      ),
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 28, vertical: 14),
                      decoration: BoxDecoration(
                        color: isSabotaged
                            ? const Color(0xFFB45309)
                            : const Color(0xFF16A34A),
                        borderRadius: BorderRadius.circular(30),
                        boxShadow: [
                          BoxShadow(
                            color: (isSabotaged
                                    ? const Color(0xFFB45309)
                                    : const Color(0xFF16A34A))
                                .withValues(alpha: 0.45),
                            blurRadius: 14,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Text(
                        isSabotaged
                            ? '[!] 통신 장애 (수리 필요)'
                            : '${mission.title} 수행하기',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),

        // ── 임포스터 전용: 사보타지 발동 버튼 ─────────────────────────────────
        if (isInProgress && isImpostor && sessionId != null)
          Positioned(
            bottom: bottomActionOffset + 120,
            left: 16,
            child: GestureDetector(
              onTap: () => _showSabotageSheet(
                context,
                sessionId!,
                amongUsState.myMissions,
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 18, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.red.shade900,
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.red.withValues(alpha: 0.4),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: const Text(
                  '사보타지 발동',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ),

        // ── 긴급 회의 소집 버튼 ────────────────────────────────────────────
        if (isInProgress && !mapState.isEliminated && sessionId != null)
          Positioned(
            bottom: bottomActionOffset + 120,
            left: 0,
            right: 0,
            child: Consumer(
              builder: (ctx, ref, _) {
                final isCooling = ref.watch(
                  gameProvider(sessionId!)
                      .select((s) => s.isMeetingCoolingDown),
                );
                return Center(
                  child: GestureDetector(
                    onTap: isCooling
                        ? null
                        : () {
                            ref
                                .read(gameProvider(sessionId!).notifier)
                                .callMeeting((res) {
                              if (ctx.mounted && res['ok'] != true) {
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      res['error']?.toString() ??
                                          '회의를 소집할 수 없습니다.',
                                    ),
                                    duration: const Duration(seconds: 2),
                                  ),
                                );
                              }
                            });
                          },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 28, vertical: 14),
                      decoration: BoxDecoration(
                        color: isCooling
                            ? Colors.grey.shade700
                            : const Color(0xFFB45309),
                        borderRadius: BorderRadius.circular(30),
                      ),
                      child: Text(
                        isCooling ? '회의 쿨타임 중...' : '긴급 회의 소집',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ),
                );
              },
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
        // ── 미션 보기 버튼 (verbal 모드 전용, 좌상단) ─────────────────────────────
        if (isVerbalMode && onShowMission != null && isInProgress)
          Positioned(
            top: MediaQuery.of(context).padding.top + 78,
            left: 16,
            child: GestureDetector(
              onTap: onShowMission,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F766E).withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.assignment_outlined,
                        color: Colors.white, size: 15),
                    SizedBox(width: 5),
                    Text(
                      '미션 보기',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        // ── verbal 모드 임포스터 킬 버튼 (좌하단) ──────────────────────────
        if (showVerbalKillButton)
          Positioned(
            left: 16,
            bottom: bottomActionOffset,
            child: _VerbalKillButton(
              hasTarget: verbalKillHasTarget,
              onPressed: verbalKillHasTarget
                  ? onVerbalKill
                  : () => ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('근처에 대상이 없습니다. 상대방에게 더 가까이 이동하세요.'),
                          duration: Duration(seconds: 2),
                        ),
                      ),
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
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFB45309),
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
                    icon: const Icon(Icons.warning_amber_rounded, size: 18),
                    label: const Text('긴급호출'),
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

void _showSabotageSheet(
  BuildContext context,
  String sessionId,
  List<am_game.Mission> missions,
) {
  final targets = missions
      .where((m) =>
          m.type == am_game.MissionType.location &&
          m.status != am_game.MissionStatus.completed &&
          !m.isSabotaged)
      .toList();

  showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF1a1a2e),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '사보타지할 미션 선택',
            style: TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          if (targets.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text(
                '사보타지할 수 있는 미션이 없습니다.',
                style: TextStyle(color: Colors.white54),
              ),
            )
          else
            ...targets.map(
              (m) => ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  m.title,
                  style: const TextStyle(color: Colors.white),
                ),
                trailing: GestureDetector(
                  onTap: () {
                    Navigator.of(ctx).pop();
                    SocketService().sendTriggerSabotage(sessionId, m.id);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.red.shade800,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                      '발동',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class _VerbalKillButton extends StatelessWidget {
  const _VerbalKillButton({
    required this.hasTarget,
    required this.onPressed,
  });

  final bool hasTarget;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: hasTarget ? Colors.red : Colors.grey.shade700,
          borderRadius: BorderRadius.circular(18),
          boxShadow: hasTarget
              ? [
                  BoxShadow(
                    color: Colors.red.withValues(alpha: 0.45),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  )
                ]
              : [],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasTarget ? Icons.dangerous_rounded : Icons.dangerous_outlined,
              color: Colors.white,
              size: 22,
            ),
            const SizedBox(width: 8),
            Text(
              hasTarget ? '제거' : '범위 밖',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ],
        ),
      ),
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
