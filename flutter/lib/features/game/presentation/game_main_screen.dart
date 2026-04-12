import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';

import '../../../core/services/socket_service.dart';
import '../../../core/providers/connection_provider.dart'; // ★ 추가된 Provider
import '../../auth/data/auth_repository.dart';
import '../../home/data/session_repository.dart';
import '../../map/presentation/map_leaf_widgets.dart';
import '../../map/presentation/map_overlay_widgets.dart';
import '../../map/presentation/map_screen.dart';
import '../../map/presentation/map_session_models.dart';
import '../data/game_models.dart';
import '../providers/game_provider.dart';
import 'game_meeting_screen.dart';
import 'widgets/ai_chat_panel.dart'; 

class GameMainScreen extends ConsumerStatefulWidget {
  const GameMainScreen({
    super.key,
    required this.sessionId,
    required this.sessionType,
  });

  final String sessionId;
  final SessionType sessionType;

  @override
  ConsumerState<GameMainScreen> createState() => _GameMainScreenState();
}

class _GameMainScreenState extends ConsumerState<GameMainScreen>
    with WidgetsBindingObserver {

  // ── KILL 쿨타임 ──────────────────────────────────────────────────────────────
  // BT/UWB 연동 후 proximateTargetId 가 설정되면 자동 활성화됩니다.
  // 현재는 proximateTargetId != null 조건만 체크하며 실제 근접 탐지는 추후 구현합니다.
  static const int _kKillCooldownSecs = 30;
  int _killCooldownSecs = 0;
  Timer? _killCooldownTimer;

  void _handleKill(String targetId) {
    if (_killCooldownSecs > 0) return;
    ref.read(gameProvider(widget.sessionId).notifier).sendKill(targetId);
    _startKillCooldown();
  }

  void _startKillCooldown() {
    setState(() => _killCooldownSecs = _kKillCooldownSecs);
    _killCooldownTimer?.cancel();
    _killCooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) { timer.cancel(); return; }
      setState(() {
        _killCooldownSecs--;
        if (_killCooldownSecs <= 0) {
          _killCooldownSecs = 0;
          timer.cancel();
          _killCooldownTimer = null;
        }
      });
    });
  }
  // ─────────────────────────────────────────────────────────────────────────────

  // ── [Task 2] AppLifecycle 감지 ──────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _killCooldownTimer?.cancel(); // KILL 쿨타임 타이머 정리
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 앱이 백그라운드에서 포그라운드로 복귀할 때 호출됩니다.
  /// OS가 백그라운드에서 소켓 전송을 일시 중단했을 수 있으므로,
  /// 최신 게임 상태와 세션 스냅샷을 즉시 재요청하여 일관성을 복구합니다.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      debugPrint('[App] 포그라운드 복귀 → 소켓 상태 즉시 동기화 시작');
      // 1) 게임 상태 재요청 (역할·미션·투표 등)
      SocketService().requestGameState(widget.sessionId);
      // 2) 세션 재참가 → 서버가 session:snapshot 을 응답하여
      //    멤버 위치·상태가 최신으로 복구됩니다.
      SocketService().emit(
        SocketEvents.joinSession,
        {'sessionId': widget.sessionId},
      );
    }
  }
  // ────────────────────────────────────────────────────────────────────────────

  // ── 누락되었던 필수 기능 메서드 복구 ──

  Future<void> _openMapSheet() {
    final mapState = ref.read(mapSessionProvider(widget.sessionId));
    final myUserId = ref.read(authProvider).valueOrNull?.id;
    final isGhostMode = mapState.eliminatedUserIds.contains(myUserId);

    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.9,
        child: _GameMapSheet(
          sessionId: widget.sessionId,
          sessionType: widget.sessionType,
          isGhostMode: isGhostMode,
        ),
      ),
    );
  }

  Future<void> _openMissionSheet() {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final gameState = ref.read(gameProvider(widget.sessionId));
        final completed = (gameState.missionProgress['completed'] as num?)?.toInt() ?? 0;
        final total = (gameState.missionProgress['total'] as num?)?.toInt() ?? 0;
        final rawPercent = (gameState.missionProgress['percent'] as num?)?.toDouble() ??
            (total > 0 ? completed / total : 0);
        final progress = ((rawPercent > 1 ? rawPercent / 100 : rawPercent).clamp(0.0, 1.0) as num).toDouble();

        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.5,
          minChildSize: 0.35,
          maxChildSize: 0.85,
          builder: (context, scrollController) {
            return DecoratedBox(
              decoration: const BoxDecoration(
                color: Color(0xFFF7F8FB),
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  children: [
                    const SizedBox(height: 12),
                    Container(
                      width: 44, height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade400,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('미션 목록', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 10),
                          Text('진행도 $completed / $total (${(progress * 100).round()}%)',
                              style: TextStyle(color: Colors.grey.shade700)),
                          const SizedBox(height: 8),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(999),
                            child: LinearProgressIndicator(
                              value: progress,
                              minHeight: 10,
                              backgroundColor: Colors.green.withValues(alpha: 0.15),
                              valueColor: const AlwaysStoppedAnimation<Color>(Colors.green),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: gameState.missions.isEmpty
                          ? Center(child: Text('표시할 미션이 아직 없습니다.', style: TextStyle(color: Colors.grey.shade600)))
                          : ListView.separated(
                              controller: scrollController,
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                              itemCount: gameState.missions.length,
                              separatorBuilder: (_, __) => const SizedBox(height: 12),
                              itemBuilder: (context, index) {
                                final mission = gameState.missions[index];
                                final isDone = mission.isCompleted;
                                return Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(18),
                                    border: Border.all(
                                      color: isDone ? Colors.green.withValues(alpha: 0.35) : Colors.grey.shade200,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 42, height: 42,
                                        decoration: BoxDecoration(
                                          color: isDone ? Colors.green.withValues(alpha: 0.14) : Colors.orange.withValues(alpha: 0.12),
                                          shape: BoxShape.circle,
                                        ),
                                        child: Icon(
                                          isDone ? Icons.check_rounded : Icons.assignment_turned_in_outlined,
                                          color: isDone ? Colors.green : Colors.orange,
                                        ),
                                      ),
                                      const SizedBox(width: 14),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(mission.title.isEmpty ? mission.id : mission.title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                                            const SizedBox(height: 4),
                                            Text([if (mission.zone.isNotEmpty) mission.zone, mission.status].join(' • '), style: TextStyle(color: Colors.grey.shade600)),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showReportSheet(MapSessionState mapState) async {
    final deadPlayers = mapState.eliminatedUserIds
        .map((userId) => mapState.members[userId])
        .whereType<MemberState>()
        .toList();

    if (deadPlayers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('신고할 시체가 없습니다.')));
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              const Text('시체 신고', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              for (final player in deadPlayers)
                ListTile(
                  leading: const CircleAvatar(backgroundColor: Color(0x1AFF3B30), child: Icon(Icons.dangerous, color: Colors.red)),
                  title: Text(player.nickname),
                  subtitle: Text(player.userId),
                  onTap: () {
                    Navigator.of(context).pop();
                    ref.read(gameProvider(widget.sessionId).notifier).sendReport(player.userId);
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  void _handleEmergency() {
    ref.read(gameProvider(widget.sessionId).notifier).sendEmergency((result) {
      if (!mounted || result['ok'] == true) return;
      final error = result['error']?.toString() ?? '회의를 소집할 수 없습니다.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
    });
  }

  @override
  Widget build(BuildContext context) {
    // ── 네비게이션 및 사이드 이펙트 처리 ──
    ref.listen<AmongUsGameState>(
      gameProvider(widget.sessionId),
      (previous, next) {
        if (previous?.shouldNavigateToRole != true && next.shouldNavigateToRole) {
          context.push('/game/${widget.sessionId}/role');
          ref.read(gameProvider(widget.sessionId).notifier).resetRoleNavigation();
        }
        // gameOverWinner: null = 진행 중, 'crew'|'impostor' = 게임 종료
        if (previous?.gameOverWinner == null && next.gameOverWinner != null) {
          final winner = next.gameOverWinner!;
          context.go('/game/${widget.sessionId}/result/$winner');
        }
      },
    );

    ref.listen<MapSessionState>(
      mapSessionProvider(widget.sessionId),
      (previous, next) {
        if (previous?.wasKicked != true && next.wasKicked) {
          context.go('/'); 
        }
      },
    );

    // ── 상태 읽기 ──
    final gameState = ref.watch(gameProvider(widget.sessionId));
    final mapState = ref.watch(mapSessionProvider(widget.sessionId));
    final authUser = ref.watch(authProvider).valueOrNull;
    
    // 네트워크 연결 상태
    final isConnectedAsync = ref.watch(socketConnectionProvider);
    final isConnected = isConnectedAsync.value ?? true;

    // 변수 계산
    final myUserId = authUser?.id;
    final isGhostMode = mapState.eliminatedUserIds.contains(myUserId);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final isKeyboardVisible = bottomInset > 0;

    // 미션 진행도 계산
    final progressCompleted = (gameState.missionProgress['completed'] as num?)?.toInt() ?? 0;
    final progressTotal = (gameState.missionProgress['total'] as num?)?.toInt() ?? 0;
    final rawPercent = (gameState.missionProgress['percent'] as num?)?.toDouble() ??
        (progressTotal > 0 ? progressCompleted / progressTotal : 0);
    final progress = ((rawPercent > 1 ? rawPercent / 100 : rawPercent).clamp(0.0, 1.0) as num).toDouble();

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: const Color(0xFFF1F5F9),
      body: SafeArea(
        child: Stack(
          children: [
            // 메인 화면 레이아웃
            DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFFEAF3FF), Color(0xFFF4F6FB), Color(0xFFF8FAFC)],
                ),
              ),
              child: Column(
                children: [
                  if (widget.sessionType != SessionType.defaultType)
                    _GameMainTopBar(
                      role: gameState.myRole,
                      progress: progress,
                      completed: progressCompleted,
                      total: progressTotal,
                      coinCount: 0, // Provider에 추가 연동 필요 (현재 임시 0)
                    ),
                  
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      child: ClipRRect(
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                        child: AIChatPanel(
                          sessionId: widget.sessionId,
                          isGhostMode: isGhostMode,
                          height: double.infinity,
                        ),
                      ),
                    ),
                  ),

                  if (!isKeyboardVisible)
                    _GameBottomDock(
                      actions: [
                        // ── KILL 버튼 (임포스터 전용, 왼쪽 배치) ────────────────
                        // 활성 조건: 임포스터 && 쿨타임 없음 && 근접 대상 존재
                        // 근접 대상(proximateTargetId)은 BT/UWB 연동 후 자동 설정됩니다.
                        // 현재는 UI만 구성하고 실제 근접 탐지 로직은 추후 구현합니다.
                        if (widget.sessionType == SessionType.verbal &&
                            gameState.myRole?.isImpostor == true &&
                            !isGhostMode)
                          _GameActionItem(
                            icon: Icons.close,
                            // 쿨타임 중엔 남은 시간 표시
                            label: _killCooldownSecs > 0
                                ? '킬 (${_killCooldownSecs}s)'
                                : '킬',
                            backgroundColor: const Color(0xFF7F1D1D),
                            // TODO: proximateTargetId는 BT/UWB 근접 탐지 구현 후 활성화됨
                            onTap: (_killCooldownSecs == 0 &&
                                    mapState.proximateTargetId != null)
                                ? () => _handleKill(mapState.proximateTargetId!)
                                : null,
                          ),

                        // ── 지도 (전체 공통) ──────────────────────────────────
                        _GameActionItem(
                          icon: Icons.map_outlined, label: '지도',
                          backgroundColor: const Color(0xFF1D4ED8),
                          onTap: _openMapSheet,
                        ),

                        // ── 시체 신고 (verbal 전용) ───────────────────────────
                        if (widget.sessionType == SessionType.verbal)
                          _GameActionItem(
                            icon: Icons.report_gmailerrorred_rounded, label: '시체 신고',
                            backgroundColor: const Color(0xFFD14343),
                            onTap: (!isGhostMode && mapState.eliminatedUserIds.isNotEmpty)
                                ? () => _showReportSheet(mapState) : null,
                          ),

                        // ── 긴급호출 (verbal 전용, 전체 멤버 사용 가능) ──────
                        if (widget.sessionType == SessionType.verbal)
                          _GameActionItem(
                            icon: Icons.warning_amber_rounded, label: '긴급호출',
                            backgroundColor: const Color(0xFFB45309),
                            onTap: !isGhostMode ? _handleEmergency : null,
                          ),

                        // ── 미션 (location 전용) ──────────────────────────────
                        if (widget.sessionType == SessionType.location)
                          _GameActionItem(
                            icon: Icons.assignment_outlined, label: '미션',
                            backgroundColor: const Color(0xFF0F766E),
                            onTap: !isGhostMode ? _openMissionSheet : null,
                          ),
                      ],
                    ),
                ],
              ),
            ),

            // 유령 모드 오버레이
            if (isGhostMode)
              Positioned.fill(
                child: AbsorbPointer(
                  absorbing: true,
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.28),
                    alignment: Alignment.center,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text('사망 - 유령으로 관전 중', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
              ),

            // 오프라인(네트워크 단절) 경고 배너
            if (!isConnected)
              Positioned(
                top: 0, left: 0, right: 0,
                child: TweenAnimationBuilder<double>(
                  duration: const Duration(milliseconds: 300),
                  tween: Tween(begin: -50.0, end: 0.0),
                  builder: (context, value, child) {
                    return Transform.translate(offset: Offset(0, value), child: child);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    color: Colors.redAccent,
                    alignment: Alignment.center,
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)),
                        SizedBox(width: 12),
                        Text('서버와 연결이 끊겼습니다. 재연결 중...', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ==========================================
// 하위 위젯들은 기존 코드와 완벽하게 동일합니다.
// ==========================================

class _GameMainTopBar extends StatelessWidget {
  const _GameMainTopBar({required this.role, required this.progress, required this.completed, required this.total, required this.coinCount});
  final GameRole? role; final double progress; final int completed; final int total; final int coinCount;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: role == null ? const SizedBox.shrink() : Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(color: role!.isImpostor ? Colors.red.withValues(alpha: 0.14) : Colors.green.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(16)),
              child: Text(role!.isImpostor ? '임포스터' : '크루원', textAlign: TextAlign.center, style: TextStyle(color: role!.isImpostor ? Colors.red : Colors.green, fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 18, offset: const Offset(0, 8))]),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('미션 진행도 $completed / $total', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                  const SizedBox(height: 8),
                  ClipRRect(borderRadius: BorderRadius.circular(999), child: LinearProgressIndicator(value: progress, minHeight: 10, backgroundColor: Colors.green.withValues(alpha: 0.12), valueColor: const AlwaysStoppedAnimation<Color>(Colors.green))),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(color: const Color(0xFFFFF6DA), borderRadius: BorderRadius.circular(18)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.monetization_on_rounded, color: Color(0xFFC58A00)), const SizedBox(width: 6),
                Text('$coinCount', style: const TextStyle(color: Color(0xFFC58A00), fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GameBottomDock extends StatelessWidget {
  const _GameBottomDock({required this.actions});
  final List<_GameActionItem> actions;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(color: Colors.white, boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 24, offset: const Offset(0, -8))]),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              child: Row(
                children: [
                  for (var index = 0; index < actions.length; index++) ...[
                    Expanded(child: _GameActionButton(item: actions[index])),
                    if (index != actions.length - 1) const SizedBox(width: 10),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GameActionButton extends StatelessWidget {
  const _GameActionButton({required this.item});
  final _GameActionItem item;

  @override
  Widget build(BuildContext context) {
    final enabled = item.onTap != null;
    return SizedBox(
      height: 56,
      child: ElevatedButton.icon(
        onPressed: item.onTap,
        icon: Icon(item.icon), label: Text(item.label),
        style: ElevatedButton.styleFrom(
          backgroundColor: enabled ? item.backgroundColor : const Color(0xFFB7BDC8),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        ),
      ),
    );
  }
}

class _GameActionItem {
  const _GameActionItem({required this.icon, required this.label, required this.backgroundColor, required this.onTap});
  final IconData icon; final String label; final Color backgroundColor; final VoidCallback? onTap;
}

class _MapMemberPanelToggle extends StatelessWidget {
  const _MapMemberPanelToggle({required this.memberCount, required this.onTap});
  final int memberCount; final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap, borderRadius: BorderRadius.circular(22),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.96), borderRadius: BorderRadius.circular(22), boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.14), blurRadius: 18, offset: const Offset(0, 8))]),
          child: Row(
            children: [
              const Icon(Icons.people_alt_rounded, color: Color(0xFF1F2937)), const SizedBox(width: 10),
              Expanded(child: Text('멤버 위치 보기 · $memberCount명', style: const TextStyle(color: Color(0xFF111827), fontWeight: FontWeight.w700))),
              const Icon(Icons.keyboard_arrow_up_rounded, color: Color(0xFF4B5563)),
            ],
          ),
        ),
      ),
    );
  }
}

class _GameMapSheet extends ConsumerStatefulWidget {
  const _GameMapSheet({required this.sessionId, required this.sessionType, required this.isGhostMode});
  final String sessionId; final SessionType sessionType; final bool isGhostMode;
  @override
  ConsumerState<_GameMapSheet> createState() => _GameMapSheetState();
}

class _GameMapSheetState extends ConsumerState<_GameMapSheet> {
  NaverMapController? _mapController;
  bool _followMe = true;
  bool _isMemberPanelExpanded = false;
  final Map<String, NMarker> _activeMarkers = {};
  Map<String, MemberState>? _previousMembers;
  bool? _previousSharingEnabled;
  Set<String>? _previousHiddenMembers;
  Set<String>? _previousEliminatedUserIds;
  String? _previousUserId;

  @override
  Widget build(BuildContext context) {
    final mapState = ref.watch(mapSessionProvider(widget.sessionId));
    final gameState = ref.watch(gameProvider(widget.sessionId));
    final authUser = ref.watch(authProvider).valueOrNull;
    final myPosition = mapState.myPosition;
    final myUserId = authUser?.id;
    final activeModules = widget.sessionType.toModules().toSet();

    if (_followMe && myPosition != null && _mapController != null) {
      _mapController!.updateCamera(NCameraUpdate.scrollAndZoomTo(target: NLatLng(myPosition.latitude, myPosition.longitude))..setAnimation(animation: NCameraAnimation.easing));
    }

    if (!identical(_previousMembers, mapState.members) || _previousSharingEnabled != mapState.sharingEnabled || !identical(_previousHiddenMembers, mapState.hiddenMembers) || !identical(_previousEliminatedUserIds, mapState.eliminatedUserIds) || _previousUserId != myUserId) {
      _previousMembers = mapState.members; _previousSharingEnabled = mapState.sharingEnabled; _previousHiddenMembers = mapState.hiddenMembers; _previousEliminatedUserIds = mapState.eliminatedUserIds; _previousUserId = myUserId;
      _syncMarkers(mapState.members, myUserId, mapState.sharingEnabled, mapState.hiddenMembers, mapState.eliminatedUserIds);
    }

    final canUseChaseAction = widget.sessionType == SessionType.chase && !widget.isGhostMode && !mapState.isEliminated && mapState.proximateTargetId != null && mapState.gameState.status == 'in_progress';
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final memberCount = mapState.members.length;
    final memberPanelReserve = _isMemberPanelExpanded ? 168.0 + bottomPadding : 72.0 + bottomPadding;
    final floatingControlsBottom = memberPanelReserve + (canUseChaseAction ? 88 : 20);
    final chaseButtonBottom = memberPanelReserve + 16;

    return Material(
      color: Colors.transparent,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: ColoredBox(
          color: Colors.white,
          child: Stack(
            children: [
              NaverMap(
                options: NaverMapViewOptions(
                  initialCameraPosition: NCameraPosition(target: myPosition != null ? NLatLng(myPosition.latitude, myPosition.longitude) : const NLatLng(37.5665, 126.9780), zoom: 14),
                  locationButtonEnable: false, zoomGesturesEnable: true,
                ),
                onMapReady: (controller) {
                  _mapController = controller;
                  _syncMarkers(mapState.members, myUserId, mapState.sharingEnabled, mapState.hiddenMembers, mapState.eliminatedUserIds);
                },
                onCameraChange: (reason, _) {
                  if (reason == NCameraUpdateReason.gesture) setState(() => _followMe = false);
                },
              ),
              Positioned(
                top: 0, left: 0, right: 0,
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Row(
                      children: [
                        Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10), decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(18)), child: const Text('지도', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700))),
                        const Spacer(),
                        IconButton.filled(onPressed: () => Navigator.of(context).pop(), style: IconButton.styleFrom(backgroundColor: Colors.black.withValues(alpha: 0.7)), icon: const Icon(Icons.close, color: Colors.white)),
                      ],
                    ),
                  ),
                ),
              ),
              MapFloatingControls(
                followMe: _followMe, bottomOffset: floatingControlsBottom,
                onFollowPressed: () {
                  setState(() => _followMe = true);
                  if (myPosition != null) _mapController?.updateCamera(NCameraUpdate.scrollAndZoomTo(target: NLatLng(myPosition.latitude, myPosition.longitude))..setAnimation(animation: NCameraAnimation.easing));
                },
                onFitPressed: () => _fitAllMembers(mapState.members, myPosition),
              ),
              if (gameState.myRole != null)
                Positioned(
                  top: 76, left: 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(color: gameState.myRole!.isImpostor ? Colors.red.withValues(alpha: 0.9) : Colors.green.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(999)),
                    child: Text(gameState.myRole!.isImpostor ? '임포스터' : '크루원', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                  ),
                ),
              if (widget.sessionType == SessionType.chase)
                Positioned(
                  left: 16, right: 16, bottom: chaseButtonBottom,
                  child: SafeArea(
                    top: false,
                    child: SizedBox(
                      height: 54,
                      child: ElevatedButton.icon(
                        onPressed: canUseChaseAction ? () => ref.read(mapSessionProvider(widget.sessionId).notifier).sendKillAction(mapState.proximateTargetId!) : null,
                        style: ElevatedButton.styleFrom(backgroundColor: canUseChaseAction ? Colors.red : Colors.grey, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
                        icon: Icon(activeModules.contains('tag') ? Icons.touch_app_rounded : Icons.gps_fixed_rounded),
                        label: Text(activeModules.contains('tag') ? '태그' : '킬', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                      ),
                    ),
                  ),
                ),
              if (widget.isGhostMode)
                Positioned.fill(
                  child: AbsorbPointer(
                    absorbing: true,
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.18), alignment: Alignment.topCenter, padding: const EdgeInsets.only(top: 76),
                      child: Container(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12), decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(16)), child: const Text('사망 - 유령으로 관전 중', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700))),
                    ),
                  ),
                ),
              if (_isMemberPanelExpanded)
                Positioned(
                  bottom: 0, left: 0, right: 0,
                  child: MapBottomMemberPanel(
                    members: mapState.members.values.toList(), myPosition: myPosition, hiddenMembers: mapState.hiddenMembers, eliminatedUserIds: mapState.eliminatedUserIds,
                    onSOS: widget.isGhostMode ? () => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('유령 상태에서는 SOS를 사용할 수 없습니다.'))) : () => ref.read(mapSessionProvider(widget.sessionId).notifier).triggerSOS(),
                    onMemberTap: (member) {
                      if (member.lat == 0 && member.lng == 0) return;
                      setState(() => _followMe = false);
                      _mapController?.updateCamera(NCameraUpdate.scrollAndZoomTo(target: NLatLng(member.lat, member.lng), zoom: 15)..setAnimation(animation: NCameraAnimation.easing));
                    },
                    onHideToggle: (userId) => ref.read(mapSessionProvider(widget.sessionId).notifier).toggleHideMember(userId),
                  ),
                )
              else
                Positioned(left: 16, right: 16, bottom: 16 + bottomPadding, child: _MapMemberPanelToggle(memberCount: memberCount, onTap: () => setState(() => _isMemberPanelExpanded = true))),
              if (_isMemberPanelExpanded)
                Positioned(
                  right: 16, bottom: memberPanelReserve - 8,
                  child: SafeArea(
                    top: false,
                    child: TextButton.icon(
                      onPressed: () => setState(() => _isMemberPanelExpanded = false),
                      style: TextButton.styleFrom(backgroundColor: Colors.black.withValues(alpha: 0.62), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999))),
                      icon: const Icon(Icons.keyboard_arrow_down_rounded), label: const Text('멤버 숨기기', style: TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ── [Task 3] 거리 기반 마커 클러스터링 ──────────────────────────────────────
  //
  // 알고리즘 개요 (Greedy Single-Pass Clustering):
  //   1. 유효 멤버를 순회하면서, 아직 어떤 클러스터에도 속하지 않은 멤버를
  //      기준점(anchor)으로 삼아 새 클러스터를 생성합니다.
  //   2. 나머지 미할당 멤버 중 anchor와 위·경도 차이가 모두
  //      _kClusterThreshDeg(≈5 m) 이내이면 같은 클러스터에 묶습니다.
  //   3. 클러스터 크기 == 1 → 기존 개별 마커 로직 유지
  //      클러스터 크기 >= 2 → 보라색 클러스터 마커(👥 N명) 렌더링
  //   4. 클러스터에 '나'가 포함되면 캡션에 "(나 포함)" 을 추가합니다.
  //
  // 마커 ID 전략:
  //   - 개별: userId 그대로 사용
  //   - 클러스터: "cluster_<정렬된 userId 첫 번째>" → 동일 그룹이면 같은 ID 유지

  /// 약 5 m 에 해당하는 위·경도 차이 (1° ≈ 111,111 m)
  static const double _kClusterThreshDeg = 0.000045;

  void _syncMarkers(
    Map<String, MemberState> members,
    String? myUserId,
    bool sharingEnabled,
    Set<String> hiddenMembers,
    Set<String> eliminatedUserIds,
  ) {
    if (_mapController == null) return;

    // ── 1. 유효 멤버 필터링 ──────────────────────────────────────────────────
    final validMembers = members.values.where((m) {
      if (m.lat == 0 && m.lng == 0) return false;
      if (m.userId == myUserId && !sharingEnabled) return false;
      if (hiddenMembers.contains(m.userId)) return false;
      return true;
    }).toList();

    // '나'를 앞에 배치하여 클러스터 anchor로 우선 선택되게 합니다
    validMembers.sort((a, b) {
      if (a.userId == myUserId) return -1;
      if (b.userId == myUserId) return 1;
      return 0;
    });

    // ── 2. Greedy 클러스터링 ─────────────────────────────────────────────────
    final Set<String> assigned = {};
    final List<List<MemberState>> clusters = [];

    for (final anchor in validMembers) {
      if (assigned.contains(anchor.userId)) continue;

      final cluster = <MemberState>[anchor];
      assigned.add(anchor.userId);

      for (final other in validMembers) {
        if (assigned.contains(other.userId)) continue;
        final dLat = (anchor.lat - other.lat).abs();
        final dLng = (anchor.lng - other.lng).abs();
        if (dLat < _kClusterThreshDeg && dLng < _kClusterThreshDeg) {
          cluster.add(other);
          assigned.add(other.userId);
        }
      }
      clusters.add(cluster);
    }

    // ── 3. 마커 ID 맵 구성 ───────────────────────────────────────────────────
    // key: 마커 ID,  value: 해당 클러스터의 멤버 목록
    final Map<String, List<MemberState>> markerMap = {};
    for (final cluster in clusters) {
      if (cluster.length == 1) {
        markerMap[cluster.first.userId] = cluster;
      } else {
        // 클러스터 ID = "cluster_" + 정렬된 userId 중 첫 번째
        final sortedIds = cluster.map((m) => m.userId).toList()..sort();
        markerMap['cluster_${sortedIds.first}'] = cluster;
      }
    }

    // ── 4. 사라진 마커 제거 ──────────────────────────────────────────────────
    final newMarkerIds = markerMap.keys.toSet();
    final toRemove = _activeMarkers.keys
        .where((id) => !newMarkerIds.contains(id))
        .toList();
    for (final id in toRemove) {
      final marker = _activeMarkers.remove(id);
      if (marker != null) _mapController!.deleteOverlay(marker.info);
    }

    // ── 5. 마커 추가 / 업데이트 ─────────────────────────────────────────────
    for (final entry in markerMap.entries) {
      final markerId = entry.key;
      final clusterMembers = entry.value;

      if (clusterMembers.length == 1) {
        // ── 개별 마커 (기존 로직) ────────────────────────────────────────────
        final m = clusterMembers.first;
        final isMe = m.userId == myUserId;
        final isEliminated = eliminatedUserIds.contains(m.userId);

        final pinColor = isEliminated
            ? Colors.grey
            : (isMe ? const Color(0xFF2196F3) : Colors.redAccent);
        final captionColor = isEliminated
            ? Colors.grey
            : (isMe ? const Color(0xFF2196F3) : Colors.black87);
        final captionText = isEliminated
            ? 'X ${m.nickname}'
            : (isMe ? '${m.nickname} (나)' : m.nickname);
        final subCaptionText = isEliminated ? '탈락' : _markerSnippet(m);
        final pos = NLatLng(m.lat, m.lng);
        final caption = NOverlayCaption(
            text: captionText, textSize: 14, color: captionColor, haloColor: Colors.white);
        final subCaption = NOverlayCaption(
            text: subCaptionText,
            textSize: 12,
            color: isEliminated ? Colors.grey : Colors.grey.shade700,
            haloColor: Colors.white);

        if (_activeMarkers.containsKey(markerId)) {
          final marker = _activeMarkers[markerId]!;
          marker.setPosition(pos);
          marker.setIconTintColor(pinColor);
          marker.setCaption(caption);
          marker.setSubCaption(subCaption);
        } else {
          final marker = NMarker(id: markerId, position: pos)
            ..setIconTintColor(pinColor)
            ..setCaption(caption)
            ..setSubCaption(subCaption);
          _activeMarkers[markerId] = marker;
          _mapController!.addOverlay(marker);
        }
      } else {
        // ── 클러스터 마커 ────────────────────────────────────────────────────
        final count = clusterMembers.length;
        final hasMe = clusterMembers.any((m) => m.userId == myUserId);

        // 클러스터 중심: 멤버 좌표 평균
        final avgLat =
            clusterMembers.map((m) => m.lat).reduce((a, b) => a + b) / count;
        final avgLng =
            clusterMembers.map((m) => m.lng).reduce((a, b) => a + b) / count;
        final pos = NLatLng(avgLat, avgLng);

        // '나'가 포함된 클러스터는 캡션으로 명시
        final captionText = hasMe ? '👥 $count명 (나 포함)' : '👥 $count명';
        // 서브캡션: 멤버 닉네임 나열
        final nicknames = clusterMembers.map((m) => m.nickname).join(', ');

        final pinColor = Colors.purple;
        final caption = NOverlayCaption(
            text: captionText,
            textSize: 14,
            color: Colors.purple,
            haloColor: Colors.white);
        final subCaption = NOverlayCaption(
            text: nicknames,
            textSize: 11,
            color: Colors.grey.shade700,
            haloColor: Colors.white);

        if (_activeMarkers.containsKey(markerId)) {
          final marker = _activeMarkers[markerId]!;
          marker.setPosition(pos);
          marker.setIconTintColor(pinColor);
          marker.setCaption(caption);
          marker.setSubCaption(subCaption);
        } else {
          final marker = NMarker(id: markerId, position: pos)
            ..setIconTintColor(pinColor)
            ..setCaption(caption)
            ..setSubCaption(subCaption);
          _activeMarkers[markerId] = marker;
          _mapController!.addOverlay(marker);
        }
      }
    }
  }
  // ─────────────────────────────────────────────────────────────────────────────

  String _markerSnippet(MemberState member) {
    final parts = <String>[member.status == 'moving' ? '이동중' : '대기'];
    if (member.battery != null) parts.add('배터리 ${member.battery}%');
    return parts.join(' • ');
  }

  void _fitAllMembers(Map<String, MemberState> members, Position? myPosition) {
    if (_mapController == null) return;
    setState(() => _followMe = false);
    final points = <NLatLng>[
      if (myPosition != null) NLatLng(myPosition.latitude, myPosition.longitude),
      ...members.values.where((member) => member.lat != 0 || member.lng != 0).map((member) => NLatLng(member.lat, member.lng)),
    ];
    if (points.isEmpty) return;
    if (points.length == 1) {
      _mapController!.updateCamera(NCameraUpdate.scrollAndZoomTo(target: points.first, zoom: 15)..setAnimation(animation: NCameraAnimation.easing));
      return;
    }
    var minLat = points.first.latitude; var maxLat = points.first.latitude;
    var minLng = points.first.longitude; var maxLng = points.first.longitude;
    for (final point in points) {
      minLat = math.min(minLat, point.latitude); maxLat = math.max(maxLat, point.latitude);
      minLng = math.min(minLng, point.longitude); maxLng = math.max(maxLng, point.longitude);
    }
    final bounds = NLatLngBounds(southWest: NLatLng(minLat, minLng), northEast: NLatLng(maxLat, maxLng));
    _mapController!.updateCamera(NCameraUpdate.fitBounds(bounds, padding: const EdgeInsets.all(80))..setAnimation(animation: NCameraAnimation.easing));
  }
}