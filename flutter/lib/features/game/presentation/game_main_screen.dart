import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';

import '../../../core/services/socket_service.dart';
import '../../auth/data/auth_repository.dart';
import '../../home/data/session_repository.dart';
import '../../map/presentation/map_leaf_widgets.dart';
import '../../map/presentation/map_overlay_widgets.dart';
import '../../map/presentation/map_screen.dart';
import '../../map/presentation/map_session_models.dart';
import '../data/game_models.dart';
import '../providers/game_provider.dart';
import 'game_meeting_screen.dart';

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

class _GameMainScreenState extends ConsumerState<GameMainScreen> {
  final SocketService _socket = SocketService();
  final TextEditingController _questionController = TextEditingController();
  final ScrollController _feedScrollController = ScrollController();
  final List<StreamSubscription> _subscriptions = [];
  final List<_FeedEntry> _feedEntries = [];

  bool _awaitingReply = false;
  bool _meetingRouteOpen = false;
  bool _isGhostMode = false;
  bool _didNavigateToResult = false;
  int _coinCount = 0;
  String? _pendingQuestion;

  @override
  void initState() {
    super.initState();
    _subscribeToSocketEvents();
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _questionController.dispose();
    _feedScrollController.dispose();
    super.dispose();
  }

  void _subscribeToSocketEvents() {
    _subscriptions.add(
      _socket.onGameEvent(SocketService.gameAiMessage).listen((data) {
        if (!mounted) return;

        final coins = _extractCoinCount(data);
        if (coins != null && coins != _coinCount) {
          setState(() => _coinCount = coins);
        }

        _appendFeed(_FeedEntry.fromAiMessage(data));
      }),
    );

    _subscriptions.add(
      _socket.onGameEvent(SocketService.gameAiReply).listen((data) {
        if (!mounted) return;

        final coins = _extractCoinCount(data);
        final question =
            _readString(data, ['question']) ?? _pendingQuestion ?? '';
        final answer = _readString(data, ['answer', 'message', 'text']) ??
            'AI 응답이 도착하지 않았습니다.';

        setState(() {
          if (coins != null) {
            _coinCount = coins;
          }
          _awaitingReply = false;
          _pendingQuestion = null;
        });

        _appendFeed(_FeedEntry.aiReply(question: question, answer: answer));
      }),
    );

    _subscriptions.add(
      _socket.onGameEvent(SocketService.gameRoleAssigned).listen((data) {
        if (!mounted) return;
        final coins = _extractCoinCount(data);
        if (coins != null && coins != _coinCount) {
          setState(() => _coinCount = coins);
        }
      }),
    );

    _subscriptions.add(
      _socket.onGameEvent(SocketService.gameMissionProgress).listen((data) {
        if (!mounted) return;
        final coins = _extractCoinCount(data);
        if (coins != null && coins != _coinCount) {
          setState(() => _coinCount = coins);
        }
      }),
    );

    if (widget.sessionType == SessionType.verbal) {
      _subscriptions.add(
        _socket.onGameEvent(SocketService.gameMeetingStarted).listen((_) {
          _openMeetingScreen();
        }),
      );

      _subscriptions.add(
        _socket.onGameEvent(SocketService.gameMeetingEnded).listen((_) {
          if (_meetingRouteOpen && mounted) {
            Navigator.of(context).maybePop();
          }
        }),
      );
    }

    _subscriptions.add(
      _socket.onGameEvent(SocketService.gameOver).listen((data) {
        if (!mounted || _didNavigateToResult) return;

        final winner = _readString(
              data,
              ['winner', 'winnerTeam', 'team', 'winnerId'],
            ) ??
            'unknown';
        final reason = _readString(data, ['reason', 'message', 'summary']);
        final uri = Uri(
          path: '/game/${widget.sessionId}/result/$winner',
          queryParameters:
              reason == null || reason.isEmpty ? null : {'reason': reason},
        );

        _didNavigateToResult = true;
        context.go(uri.toString());
      }),
    );

    _subscriptions.add(
      _socket.onPlayerEliminated.listen((data) {
        if (!mounted) return;

        final myUserId = ref.read(authProvider).valueOrNull?.id;
        final eliminatedUserId = data['userId']?.toString();
        if (myUserId == null || eliminatedUserId != myUserId) return;

        setState(() {
          _isGhostMode = true;
          _awaitingReply = false;
          _pendingQuestion = null;
        });
      }),
    );
  }

  void _appendFeed(_FeedEntry entry) {
    setState(() => _feedEntries.add(entry));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_feedScrollController.hasClients) return;
      _feedScrollController.animateTo(
        _feedScrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _openMeetingScreen() async {
    if (_meetingRouteOpen || !mounted) return;

    final authUser = ref.read(authProvider).valueOrNull;
    _meetingRouteOpen = true;

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GameMeetingScreen(
          sessionId: widget.sessionId,
          memberNames: _memberNames(),
          myUserId: authUser?.id ?? '',
        ),
      ),
    );

    if (mounted) {
      _meetingRouteOpen = false;
    }
  }

  Map<String, String> _memberNames() {
    final names = <String, String>{};
    final mapState = ref.read(mapSessionProvider(widget.sessionId));

    for (final entry in mapState.members.entries) {
      names[entry.key] = entry.value.nickname;
    }

    final sessions =
        ref.read(sessionListProvider).valueOrNull ?? const <Session>[];
    for (final session in sessions) {
      if (session.id != widget.sessionId) continue;
      for (final member in session.members) {
        names.putIfAbsent(member.userId, () => member.nickname);
      }
      break;
    }

    final authUser = ref.read(authProvider).valueOrNull;
    if (authUser != null) {
      names.putIfAbsent(authUser.id, () => authUser.nickname);
    }

    return names;
  }

  int? _extractCoinCount(Map<String, dynamic> data) {
    final raw = data['coinCount'] ?? data['coins'] ?? data['coin'];
    if (raw is num) return raw.toInt();
    return null;
  }

  String? _readString(Map<String, dynamic> data, List<String> keys) {
    for (final key in keys) {
      final value = data[key];
      if (value == null) continue;
      final text = value.toString().trim();
      if (text.isNotEmpty) {
        return text;
      }
    }
    return null;
  }

  void _sendQuestion() {
    if (_awaitingReply || _isGhostMode) return;

    final question = _questionController.text.trim();
    if (question.isEmpty) return;

    setState(() {
      _awaitingReply = true;
      _pendingQuestion = question;
    });
    _questionController.clear();

    _socket.sendAiQuestion(widget.sessionId, question, (response) {
      if (!mounted) return;
      if (response['ok'] == true) return;

      setState(() {
        _awaitingReply = false;
        _pendingQuestion = null;
      });
      _appendFeed(
        _FeedEntry.system(
          message: 'AI 응답 요청 실패: ${response['error'] ?? 'unknown'}',
        ),
      );
    });
  }

  Future<void> _openMapSheet() {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.9,
        child: _GameMapSheet(
          sessionId: widget.sessionId,
          sessionType: widget.sessionType,
          isGhostMode: _isGhostMode,
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
        final completed =
            (gameState.missionProgress['completed'] as num?)?.toInt() ?? 0;
        final total =
            (gameState.missionProgress['total'] as num?)?.toInt() ?? 0;
        final rawPercent =
            (gameState.missionProgress['percent'] as num?)?.toDouble() ??
                (total > 0 ? completed / total : 0);
        final progress = ((rawPercent > 1 ? rawPercent / 100 : rawPercent)
                .clamp(0.0, 1.0) as num)
            .toDouble();

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
                      width: 44,
                      height: 4,
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
                          const Text(
                            '미션 목록',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            '진행도 $completed / $total (${(progress * 100).round()}%)',
                            style: TextStyle(color: Colors.grey.shade700),
                          ),
                          const SizedBox(height: 8),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(999),
                            child: LinearProgressIndicator(
                              value: progress,
                              minHeight: 10,
                              backgroundColor:
                                  Colors.green.withValues(alpha: 0.15),
                              valueColor: const AlwaysStoppedAnimation<Color>(
                                Colors.green,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: gameState.missions.isEmpty
                          ? Center(
                              child: Text(
                                '표시할 미션이 아직 없습니다.',
                                style: TextStyle(color: Colors.grey.shade600),
                              ),
                            )
                          : ListView.separated(
                              controller: scrollController,
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                              itemBuilder: (context, index) {
                                final mission = gameState.missions[index];
                                final isDone = mission.isCompleted;
                                return Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(18),
                                    border: Border.all(
                                      color: isDone
                                          ? Colors.green.withValues(alpha: 0.35)
                                          : Colors.grey.shade200,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 42,
                                        height: 42,
                                        decoration: BoxDecoration(
                                          color: isDone
                                              ? Colors.green
                                                  .withValues(alpha: 0.14)
                                              : Colors.orange
                                                  .withValues(alpha: 0.12),
                                          shape: BoxShape.circle,
                                        ),
                                        child: Icon(
                                          isDone
                                              ? Icons.check_rounded
                                              : Icons
                                                  .assignment_turned_in_outlined,
                                          color: isDone
                                              ? Colors.green
                                              : Colors.orange,
                                        ),
                                      ),
                                      const SizedBox(width: 14),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              mission.title.isEmpty
                                                  ? mission.id
                                                  : mission.title,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w700,
                                                fontSize: 15,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              [
                                                if (mission.zone.isNotEmpty)
                                                  mission.zone,
                                                mission.status,
                                              ].join(' • '),
                                              style: TextStyle(
                                                color: Colors.grey.shade600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 12),
                              itemCount: gameState.missions.length,
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('신고할 시체가 없습니다.')),
      );
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
              const Text(
                '시체 신고',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              for (final player in deadPlayers)
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0x1AFF3B30),
                    child: Icon(Icons.dangerous, color: Colors.red),
                  ),
                  title: Text(player.nickname),
                  subtitle: Text(player.userId),
                  onTap: () {
                    Navigator.of(context).pop();
                    ref
                        .read(gameProvider(widget.sessionId).notifier)
                        .sendReport(player.userId);
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

      final error = result['error']?.toString() ?? '투표를 시작하지 못했습니다.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AmongUsGameState>(
      gameProvider(widget.sessionId),
      (previous, next) {
        if (previous?.shouldNavigateToRole != true &&
            next.shouldNavigateToRole) {
          context.push('/game/${widget.sessionId}/role');
          ref
              .read(gameProvider(widget.sessionId).notifier)
              .resetRoleNavigation();
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

    final gameState = ref.watch(gameProvider(widget.sessionId));
    final mapState = ref.watch(mapSessionProvider(widget.sessionId));
    final progressCompleted =
        (gameState.missionProgress['completed'] as num?)?.toInt() ?? 0;
    final progressTotal =
        (gameState.missionProgress['total'] as num?)?.toInt() ?? 0;
    final rawPercent =
        (gameState.missionProgress['percent'] as num?)?.toDouble() ??
            (progressTotal > 0 ? progressCompleted / progressTotal : 0);
    final progress = ((rawPercent > 1 ? rawPercent / 100 : rawPercent)
            .clamp(0.0, 1.0) as num)
        .toDouble();

    final showAiChat = widget.sessionType == SessionType.verbal ||
        widget.sessionType == SessionType.location;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final isKeyboardVisible = bottomInset > 0;

    return Scaffold(
      backgroundColor: const Color(0xFFF1F5F9),
      body: SafeArea(
        child: Stack(
          children: [
            DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0xFFEAF3FF),
                    Color(0xFFF4F6FB),
                    Color(0xFFF8FAFC),
                  ],
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
                      coinCount: _coinCount,
                    ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      child: _AiConsolePanel(
                        entries: _feedEntries,
                        sessionType: widget.sessionType,
                        isGhostMode: _isGhostMode,
                        isAwaitingReply: _awaitingReply,
                        pendingQuestion: _pendingQuestion,
                        scrollController: _feedScrollController,
                      ),
                    ),
                  ),
                  AnimatedPadding(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    padding: EdgeInsets.only(bottom: bottomInset),
                    child: _GameBottomDock(
                      showAiChat: showAiChat,
                      showActions: !isKeyboardVisible,
                      questionController: _questionController,
                      isAwaitingReply: _awaitingReply,
                      isGhostMode: _isGhostMode,
                      onSendQuestion: _sendQuestion,
                      actions: [
                        _GameActionItem(
                          icon: Icons.map_outlined,
                          label: '지도',
                          backgroundColor: const Color(0xFF1D4ED8),
                          onTap: _openMapSheet,
                        ),
                        if (widget.sessionType == SessionType.verbal)
                          _GameActionItem(
                            icon: Icons.report_gmailerrorred_rounded,
                            label: '시체 신고',
                            backgroundColor: const Color(0xFFD14343),
                            onTap: (!_isGhostMode &&
                                    mapState.eliminatedUserIds.isNotEmpty)
                                ? () => _showReportSheet(mapState)
                                : null,
                          ),
                        if (widget.sessionType == SessionType.verbal)
                          _GameActionItem(
                            icon: Icons.warning_amber_rounded,
                            label: '긴급',
                            backgroundColor: const Color(0xFFB45309),
                            onTap: !_isGhostMode ? _handleEmergency : null,
                          ),
                        if (widget.sessionType == SessionType.location)
                          _GameActionItem(
                            icon: Icons.assignment_outlined,
                            label: '미션',
                            backgroundColor: const Color(0xFF0F766E),
                            onTap: !_isGhostMode ? _openMissionSheet : null,
                          ),
                      ],
                    ),
                  ),
                  /* _ActionBar(
                  actions: [
                    _ActionBarItem(
                      icon: Icons.map_outlined,
                      label: '지도',
                      onTap: _openMapSheet,
                    ),
                    if (widget.sessionType == SessionType.verbal)
                      _ActionBarItem(
                        icon: Icons.report_gmailerrorred_rounded,
                        label: '시체신고',
                        onTap: (!_isGhostMode &&
                                mapState.eliminatedUserIds.isNotEmpty)
                            ? () => _showReportSheet(mapState)
                            : null,
                      ),
                    if (widget.sessionType == SessionType.verbal)
                      _ActionBarItem(
                        icon: Icons.warning_amber_rounded,
                        label: '긴급',
                        onTap: !_isGhostMode ? _handleEmergency : null,
                      ),
                    if (widget.sessionType == SessionType.location)
                      _ActionBarItem(
                        icon: Icons.assignment_outlined,
                        label: '미션',
                        onTap: !_isGhostMode ? _openMissionSheet : null,
                      ),
                  ],
                ), */
                ],
              ),
            ),
            if (_isGhostMode)
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: true,
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.28),
                    alignment: Alignment.center,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 18,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text(
                        '사망 - 유령으로 관전 중',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
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
}

class _GameMainTopBar extends StatelessWidget {
  const _GameMainTopBar({
    required this.role,
    required this.progress,
    required this.completed,
    required this.total,
    required this.coinCount,
  });

  final GameRole? role;
  final double progress;
  final int completed;
  final int total;
  final int coinCount;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: role == null
                ? const SizedBox.shrink()
                : Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: role!.isImpostor
                          ? Colors.red.withValues(alpha: 0.14)
                          : Colors.green.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      role!.isImpostor ? '임포스터' : '크루원',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: role!.isImpostor ? Colors.red : Colors.green,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '미션 진행도 $completed / $total',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 10,
                      backgroundColor: Colors.green.withValues(alpha: 0.12),
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        Colors.green,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF6DA),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.monetization_on_rounded,
                  color: Color(0xFFC58A00),
                ),
                const SizedBox(width: 6),
                Text(
                  '$coinCount',
                  style: const TextStyle(
                    color: Color(0xFFC58A00),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AiConsolePanel extends StatelessWidget {
  const _AiConsolePanel({
    required this.entries,
    required this.sessionType,
    required this.isGhostMode,
    required this.isAwaitingReply,
    required this.pendingQuestion,
    required this.scrollController,
  });

  final List<_FeedEntry> entries;
  final SessionType sessionType;
  final bool isGhostMode;
  final bool isAwaitingReply;
  final String? pendingQuestion;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: const Color(0xFFD8E1F0)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F172A).withValues(alpha: 0.08),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0xFFDCFCE7),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.smart_toy_rounded,
                    color: Color(0xFF15803D),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'AI MOYA 채널',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF111827),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        entries.isEmpty
                            ? '게임 로그와 AI 대화가 여기에 쌓입니다.'
                            : '메시지 ${entries.length}개',
                        style: TextStyle(
                          color: Colors.grey.shade600,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: isAwaitingReply
                        ? const Color(0xFFDCFCE7)
                        : const Color(0xFFE5E7EB),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    isAwaitingReply ? '응답 대기' : '실시간',
                    style: TextStyle(
                      color: isAwaitingReply
                          ? const Color(0xFF15803D)
                          : const Color(0xFF4B5563),
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(
            height: 1,
            margin: const EdgeInsets.symmetric(horizontal: 18),
            color: const Color(0xFFE5E7EB),
          ),
          Expanded(
            child: entries.isEmpty
                ? _EmptyFeed(
                    sessionType: sessionType,
                    isGhostMode: isGhostMode,
                  )
                : ListView.separated(
                    controller: scrollController,
                    padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    itemBuilder: (context, index) => _FeedCard(
                      entry: entries[index],
                    ),
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemCount: entries.length,
                  ),
          ),
          if (isAwaitingReply && pendingQuestion != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
              child: _PendingAiQuestionCard(question: pendingQuestion!),
            ),
        ],
      ),
    );
  }
}

class _PendingAiQuestionCard extends StatelessWidget {
  const _PendingAiQuestionCard({required this.question});

  final String question;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FDF4),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFBBF7D0)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              color: Color(0xFF16A34A),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'AI 답변을 기다리는 중',
                  style: TextStyle(
                    color: Color(0xFF166534),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  question,
                  style: const TextStyle(
                    color: Color(0xFF14532D),
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GameBottomDock extends StatelessWidget {
  const _GameBottomDock({
    required this.showAiChat,
    required this.showActions,
    required this.questionController,
    required this.isAwaitingReply,
    required this.isGhostMode,
    required this.onSendQuestion,
    required this.actions,
  });

  final bool showAiChat;
  final bool showActions;
  final TextEditingController questionController;
  final bool isAwaitingReply;
  final bool isGhostMode;
  final VoidCallback onSendQuestion;
  final List<_GameActionItem> actions;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 24,
            offset: const Offset(0, -8),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showAiChat)
              _AiComposerBar(
                controller: questionController,
                isLoading: isAwaitingReply,
                isEnabled: !isGhostMode,
                onSend: onSendQuestion,
              ),
            if (showActions) _GameActionDock(actions: actions),
          ],
        ),
      ),
    );
  }
}

class _AiComposerBar extends StatelessWidget {
  const _AiComposerBar({
    required this.controller,
    required this.isLoading,
    required this.isEnabled,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool isLoading;
  final bool isEnabled;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'AI MOYA에게 질문하기',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF111827),
                  ),
                ),
              ),
              if (isLoading)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFDCFCE7),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text(
                    '응답 중',
                    style: TextStyle(
                      color: Color(0xFF15803D),
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            isEnabled
                ? '단서를 묻거나 현재 상황에 대한 힌트를 요청해보세요.'
                : '유령 상태에서는 AI 채팅을 사용할 수 없습니다.',
            style: TextStyle(
              color: Colors.grey.shade600,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  enabled: isEnabled && !isLoading,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => onSend(),
                  decoration: InputDecoration(
                    hintText: isEnabled ? 'AI MOYA에게 질문하기' : '채팅 비활성화됨',
                    filled: true,
                    fillColor: const Color(0xFFF4F6FB),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(18),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 92,
                height: 52,
                child: ElevatedButton(
                  onPressed: isEnabled && !isLoading ? onSend : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF16A34A),
                    foregroundColor: Colors.white,
                    minimumSize: const Size(92, 52),
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: isLoading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          '전송',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GameActionDock extends StatelessWidget {
  const _GameActionDock({required this.actions});

  final List<_GameActionItem> actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Row(
        children: [
          for (var index = 0; index < actions.length; index++) ...[
            Expanded(child: _GameActionButton(item: actions[index])),
            if (index != actions.length - 1) const SizedBox(width: 10),
          ],
        ],
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
        icon: Icon(item.icon),
        label: Text(item.label),
        style: ElevatedButton.styleFrom(
          backgroundColor:
              enabled ? item.backgroundColor : const Color(0xFFB7BDC8),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
      ),
    );
  }
}

class _GameActionItem {
  const _GameActionItem({
    required this.icon,
    required this.label,
    required this.backgroundColor,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color backgroundColor;
  final VoidCallback? onTap;
}

class _MapMemberPanelToggle extends StatelessWidget {
  const _MapMemberPanelToggle({
    required this.memberCount,
    required this.onTap,
  });

  final int memberCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.14),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              const Icon(Icons.people_alt_rounded, color: Color(0xFF1F2937)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '멤버 위치 보기 · $memberCount명',
                  style: const TextStyle(
                    color: Color(0xFF111827),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Icon(
                Icons.keyboard_arrow_up_rounded,
                color: Color(0xFF4B5563),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyFeed extends StatelessWidget {
  const _EmptyFeed({
    required this.sessionType,
    required this.isGhostMode,
  });

  final SessionType sessionType;
  final bool isGhostMode;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isGhostMode ? Icons.visibility_rounded : Icons.smart_toy_outlined,
              size: 48,
              color: Colors.grey.shade500,
            ),
            const SizedBox(height: 16),
            const Text(
              '아직 도착한 AI 메시지가 없습니다.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              sessionType == SessionType.verbal ||
                      sessionType == SessionType.location
                  ? '아래 입력창에서 AI MOYA에게 질문하거나, 게임 진행 메시지를 기다려 보세요.'
                  : '게임 진행 메시지가 이 화면에 순서대로 쌓입니다.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.grey.shade600,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/* class _AiQuestionBar extends StatelessWidget {
  const _AiQuestionBar({
    required this.controller,
    required this.isLoading,
    required this.isEnabled,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool isLoading;
  final bool isEnabled;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      color: Colors.white,
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              enabled: isEnabled && !isLoading,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSend(),
              decoration: InputDecoration(
                hintText:
                    isEnabled ? 'AI에게 질문하기' : '유령 상태에서는 AI 채팅을 사용할 수 없습니다.',
                filled: true,
                fillColor: const Color(0xFFF4F6FB),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 92,
            height: 52,
            child: ElevatedButton(
              onPressed: isEnabled && !isLoading ? onSend : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
                minimumSize: const Size(92, 52),
                padding: const EdgeInsets.symmetric(horizontal: 18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: isLoading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text(
                      '전송',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
            ),
          ),
        ],
      ),
    );
  }
} */

/* class _ActionBar extends StatelessWidget {
  const _ActionBar({required this.actions});

  final List<_ActionBarItem> actions;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      color: Colors.white,
      child: Row(
        children: [
          for (var index = 0; index < actions.length; index++) ...[
            Expanded(child: _ActionButton(item: actions[index])),
            if (index != actions.length - 1) const SizedBox(width: 10),
          ],
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.item});

  final _ActionBarItem item;

  @override
  Widget build(BuildContext context) {
    final enabled = item.onTap != null;
    return SizedBox(
      height: 56,
      child: ElevatedButton.icon(
        onPressed: item.onTap,
        icon: Icon(item.icon),
        label: Text(item.label),
        style: ElevatedButton.styleFrom(
          backgroundColor:
              enabled ? const Color(0xFF121722) : const Color(0xFFB7BDC8),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
      ),
    );
  }
}

class _ActionBarItem {
  const _ActionBarItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
} */

class _FeedCard extends StatelessWidget {
  const _FeedCard({required this.entry});

  final _FeedEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = entry.theme;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: 6,
            decoration: BoxDecoration(
              color: theme.color,
              borderRadius: const BorderRadius.horizontal(
                left: Radius.circular(20),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: theme.color.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(theme.icon, color: theme.color),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          theme.label,
                          style: TextStyle(
                            color: theme.color,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        if (entry.question != null &&
                            entry.question!.isNotEmpty) ...[
                          Text(
                            '질문',
                            style: TextStyle(
                              color: Colors.grey.shade500,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            entry.question!,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              height: 1.5,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            '응답',
                            style: TextStyle(
                              color: Colors.grey.shade500,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                        ],
                        Text(
                          entry.message,
                          style: const TextStyle(
                            fontSize: 15,
                            height: 1.55,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FeedEntry {
  const _FeedEntry({
    required this.kind,
    required this.message,
    this.question,
  });

  final _FeedKind kind;
  final String message;
  final String? question;

  _FeedTheme get theme => switch (kind) {
        _FeedKind.narration => const _FeedTheme(
            label: 'Narration',
            color: Colors.blue,
            icon: Icons.record_voice_over_rounded,
          ),
        _FeedKind.atmosphere => const _FeedTheme(
            label: 'Atmosphere',
            color: Color(0xFF7A1F1F),
            icon: Icons.visibility_rounded,
          ),
        _FeedKind.announcement => const _FeedTheme(
            label: 'Announcement',
            color: Colors.red,
            icon: Icons.campaign_rounded,
          ),
        _FeedKind.voteResult => const _FeedTheme(
            label: 'Vote Result',
            color: Colors.orange,
            icon: Icons.how_to_vote_rounded,
          ),
        _FeedKind.gameEnd => const _FeedTheme(
            label: 'Game End',
            color: Color(0xFFC19A00),
            icon: Icons.emoji_events_rounded,
          ),
        _FeedKind.aiReply => const _FeedTheme(
            label: 'AI MOYA',
            color: Colors.green,
            icon: Icons.smart_toy_rounded,
          ),
        _FeedKind.system => const _FeedTheme(
            label: 'System',
            color: Colors.grey,
            icon: Icons.info_outline_rounded,
          ),
      };

  factory _FeedEntry.fromAiMessage(Map<String, dynamic> data) {
    final type = (data['type'] ?? data['messageType'] ?? data['category'])
        ?.toString()
        .trim()
        .toLowerCase();
    final message =
        (data['message'] ?? data['content'] ?? data['text'])?.toString().trim();

    return _FeedEntry(
      kind: switch (type) {
        'narration' => _FeedKind.narration,
        'atmosphere' => _FeedKind.atmosphere,
        'vote_result' => _FeedKind.voteResult,
        'game_end' => _FeedKind.gameEnd,
        'announcement' => _FeedKind.announcement,
        _ => _FeedKind.announcement,
      },
      message:
          (message == null || message.isEmpty) ? '표시할 메시지가 없습니다.' : message,
    );
  }

  factory _FeedEntry.aiReply({
    required String question,
    required String answer,
  }) {
    return _FeedEntry(
      kind: _FeedKind.aiReply,
      question: question,
      message: answer,
    );
  }

  factory _FeedEntry.system({required String message}) {
    return _FeedEntry(kind: _FeedKind.system, message: message);
  }
}

enum _FeedKind {
  narration,
  atmosphere,
  announcement,
  voteResult,
  gameEnd,
  aiReply,
  system,
}

class _FeedTheme {
  const _FeedTheme({
    required this.label,
    required this.color,
    required this.icon,
  });

  final String label;
  final Color color;
  final IconData icon;
}

class _GameMapSheet extends ConsumerStatefulWidget {
  const _GameMapSheet({
    required this.sessionId,
    required this.sessionType,
    required this.isGhostMode,
  });

  final String sessionId;
  final SessionType sessionType;
  final bool isGhostMode;

  @override
  ConsumerState<_GameMapSheet> createState() => _GameMapSheetState();
}

class _GameMapSheetState extends ConsumerState<_GameMapSheet> {
  NaverMapController? _mapController;
  bool _followMe = true;
  bool _isMemberPanelExpanded = false;

  Set<NMarker> _cachedMarkers = {};
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
      _mapController!.updateCamera(
        NCameraUpdate.scrollAndZoomTo(
          target: NLatLng(myPosition.latitude, myPosition.longitude),
        )..setAnimation(animation: NCameraAnimation.easing),
      );
    }

    if (!identical(_previousMembers, mapState.members) ||
        _previousSharingEnabled != mapState.sharingEnabled ||
        !identical(_previousHiddenMembers, mapState.hiddenMembers) ||
        !identical(_previousEliminatedUserIds, mapState.eliminatedUserIds) ||
        _previousUserId != myUserId) {
      _previousMembers = mapState.members;
      _previousSharingEnabled = mapState.sharingEnabled;
      _previousHiddenMembers = mapState.hiddenMembers;
      _previousEliminatedUserIds = mapState.eliminatedUserIds;
      _previousUserId = myUserId;

      _cachedMarkers = _buildMarkers(
        mapState.members,
        myUserId,
        mapState.sharingEnabled,
        mapState.hiddenMembers,
        mapState.eliminatedUserIds,
      );

      if (_mapController != null) {
        _mapController!.clearOverlays();
        _mapController!.addOverlayAll(_cachedMarkers);
      }
    }

    final canUseChaseAction = widget.sessionType == SessionType.chase &&
        !widget.isGhostMode &&
        !mapState.isEliminated &&
        mapState.proximateTargetId != null &&
        mapState.gameState.status == 'in_progress';
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final memberCount = mapState.members.length;
    final memberPanelReserve =
        _isMemberPanelExpanded ? 168.0 + bottomPadding : 72.0 + bottomPadding;
    final floatingControlsBottom =
        memberPanelReserve + (canUseChaseAction ? 88 : 20);
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
                  initialCameraPosition: NCameraPosition(
                    target: myPosition != null
                        ? NLatLng(myPosition.latitude, myPosition.longitude)
                        : const NLatLng(37.5665, 126.9780),
                    zoom: 14,
                  ),
                  locationButtonEnable: false,
                  zoomGesturesEnable: true,
                ),
                onMapReady: (controller) {
                  _mapController = controller;
                  if (_cachedMarkers.isNotEmpty) {
                    _mapController!.addOverlayAll(_cachedMarkers);
                  }
                },
                onCameraChange: (reason, _) {
                  if (reason == NCameraUpdateReason.gesture) {
                    setState(() => _followMe = false);
                  }
                },
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: const Text(
                            '지도',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const Spacer(),
                        IconButton.filled(
                          onPressed: () => Navigator.of(context).pop(),
                          style: IconButton.styleFrom(
                            backgroundColor:
                                Colors.black.withValues(alpha: 0.7),
                          ),
                          icon: const Icon(Icons.close, color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              MapFloatingControls(
                followMe: _followMe,
                bottomOffset: floatingControlsBottom,
                onFollowPressed: () {
                  setState(() => _followMe = true);
                  if (myPosition != null) {
                    _mapController?.updateCamera(
                      NCameraUpdate.scrollAndZoomTo(
                        target:
                            NLatLng(myPosition.latitude, myPosition.longitude),
                      )..setAnimation(animation: NCameraAnimation.easing),
                    );
                  }
                },
                onFitPressed: () =>
                    _fitAllMembers(mapState.members, myPosition),
              ),
              if (gameState.myRole != null)
                Positioned(
                  top: 76,
                  left: 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: gameState.myRole!.isImpostor
                          ? Colors.red.withValues(alpha: 0.9)
                          : Colors.green.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      gameState.myRole!.isImpostor ? '임포스터' : '크루원',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              if (widget.sessionType == SessionType.chase)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: chaseButtonBottom,
                  child: SafeArea(
                    top: false,
                    child: SizedBox(
                      height: 54,
                      child: ElevatedButton.icon(
                        onPressed: canUseChaseAction
                            ? () => ref
                                .read(
                                  mapSessionProvider(widget.sessionId).notifier,
                                )
                                .sendKillAction(mapState.proximateTargetId!)
                            : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor:
                              canUseChaseAction ? Colors.red : Colors.grey,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                        ),
                        icon: Icon(
                          activeModules.contains('tag')
                              ? Icons.touch_app_rounded
                              : Icons.gps_fixed_rounded,
                        ),
                        label: Text(
                          activeModules.contains('tag') ? '태그' : '킬',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (widget.isGhostMode)
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: true,
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.18),
                      alignment: Alignment.topCenter,
                      padding: const EdgeInsets.only(top: 76),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Text(
                          '사망 - 유령으로 관전 중',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              /* Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: MapBottomMemberPanel(
                  members: mapState.members.values.toList(),
                  myPosition: myPosition,
                  hiddenMembers: mapState.hiddenMembers,
                  eliminatedUserIds: mapState.eliminatedUserIds,
                  onSOS: widget.isGhostMode
                      ? () => ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('유령 상태에서는 이 기능을 사용할 수 없습니다.'),
                            ),
                          )
                      : () => ref
                          .read(mapSessionProvider(widget.sessionId).notifier)
                          .triggerSOS(),
                  onMemberTap: (member) {
                    if (member.lat == 0 && member.lng == 0) return;
                    setState(() => _followMe = false);
                    _mapController?.updateCamera(
                      NCameraUpdate.scrollAndZoomTo(
                        target: NLatLng(member.lat, member.lng),
                        zoom: 15,
                      )..setAnimation(animation: NCameraAnimation.easing),
                    );
                  },
                  onHideToggle: (userId) => ref
                      .read(mapSessionProvider(widget.sessionId).notifier)
                      .toggleHideMember(userId),
                ),
              ), */
              if (_isMemberPanelExpanded)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: MapBottomMemberPanel(
                    members: mapState.members.values.toList(),
                    myPosition: myPosition,
                    hiddenMembers: mapState.hiddenMembers,
                    eliminatedUserIds: mapState.eliminatedUserIds,
                    onSOS: widget.isGhostMode
                        ? () => ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('유령 상태에서는 SOS를 사용할 수 없습니다.'),
                              ),
                            )
                        : () => ref
                            .read(mapSessionProvider(widget.sessionId).notifier)
                            .triggerSOS(),
                    onMemberTap: (member) {
                      if (member.lat == 0 && member.lng == 0) return;
                      setState(() => _followMe = false);
                      _mapController?.updateCamera(
                        NCameraUpdate.scrollAndZoomTo(
                          target: NLatLng(member.lat, member.lng),
                          zoom: 15,
                        )..setAnimation(animation: NCameraAnimation.easing),
                      );
                    },
                    onHideToggle: (userId) => ref
                        .read(mapSessionProvider(widget.sessionId).notifier)
                        .toggleHideMember(userId),
                  ),
                )
              else
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 16 + bottomPadding,
                  child: _MapMemberPanelToggle(
                    memberCount: memberCount,
                    onTap: () => setState(() => _isMemberPanelExpanded = true),
                  ),
                ),
              if (_isMemberPanelExpanded)
                Positioned(
                  right: 16,
                  bottom: memberPanelReserve - 8,
                  child: SafeArea(
                    top: false,
                    child: TextButton.icon(
                      onPressed: () =>
                          setState(() => _isMemberPanelExpanded = false),
                      style: TextButton.styleFrom(
                        backgroundColor: Colors.black.withValues(alpha: 0.62),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      icon: const Icon(Icons.keyboard_arrow_down_rounded),
                      label: const Text(
                        '멤버 숨기기',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ),
              /* if (gameState.myRole != null)
                Positioned(
                  top: 72,
                  left: 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: gameState.myRole!.isImpostor
                          ? Colors.red.withValues(alpha: 0.92)
                          : Colors.green.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      gameState.myRole!.isImpostor ? '임포스터' : '크루원',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ), */
            ],
          ),
        ),
      ),
    );
  }

  Set<NMarker> _buildMarkers(
    Map<String, MemberState> members,
    String? myUserId,
    bool sharingEnabled,
    Set<String> hiddenMembers,
    Set<String> eliminatedUserIds,
  ) {
    final markers = <NMarker>{};

    for (final member in members.values) {
      if (member.lat == 0 && member.lng == 0) continue;

      final isMe = member.userId == myUserId;
      final isEliminated = eliminatedUserIds.contains(member.userId);
      if (isMe && !sharingEnabled) continue;
      if (hiddenMembers.contains(member.userId)) continue;

      final pinColor = isEliminated
          ? Colors.grey
          : (isMe ? const Color(0xFF2196F3) : Colors.redAccent);
      final captionColor = isEliminated
          ? Colors.grey
          : (isMe ? const Color(0xFF2196F3) : Colors.black87);
      final caption = isEliminated
          ? 'X ${member.nickname}'
          : (isMe ? '${member.nickname} (나)' : member.nickname);

      final marker = NMarker(
        id: member.userId,
        position: NLatLng(member.lat, member.lng),
      )
        ..setIconTintColor(pinColor)
        ..setCaption(
          NOverlayCaption(
            text: caption,
            textSize: 14,
            color: captionColor,
            haloColor: Colors.white,
          ),
        )
        ..setSubCaption(
          NOverlayCaption(
            text: isEliminated ? '탈락' : _markerSnippet(member),
            textSize: 12,
            color: isEliminated ? Colors.grey : Colors.grey.shade700,
            haloColor: Colors.white,
          ),
        );

      markers.add(marker);
    }

    return markers;
  }

  String _markerSnippet(MemberState member) {
    final parts = <String>[
      member.status == 'moving' ? '이동중' : '대기',
    ];
    if (member.battery != null) {
      parts.add('배터리 ${member.battery}%');
    }
    return parts.join(' • ');
  }

  void _fitAllMembers(Map<String, MemberState> members, Position? myPosition) {
    if (_mapController == null) return;

    setState(() => _followMe = false);

    final points = <NLatLng>[
      if (myPosition != null)
        NLatLng(myPosition.latitude, myPosition.longitude),
      ...members.values
          .where((member) => member.lat != 0 || member.lng != 0)
          .map((member) => NLatLng(member.lat, member.lng)),
    ];

    if (points.isEmpty) return;

    if (points.length == 1) {
      _mapController!.updateCamera(
        NCameraUpdate.scrollAndZoomTo(target: points.first, zoom: 15)
          ..setAnimation(animation: NCameraAnimation.easing),
      );
      return;
    }

    var minLat = points.first.latitude;
    var maxLat = points.first.latitude;
    var minLng = points.first.longitude;
    var maxLng = points.first.longitude;

    for (final point in points) {
      minLat = math.min(minLat, point.latitude);
      maxLat = math.max(maxLat, point.latitude);
      minLng = math.min(minLng, point.longitude);
      maxLng = math.max(maxLng, point.longitude);
    }

    final bounds = NLatLngBounds(
      southWest: NLatLng(minLat, minLng),
      northEast: NLatLng(maxLat, maxLng),
    );

    _mapController!.updateCamera(
      NCameraUpdate.fitBounds(bounds, padding: const EdgeInsets.all(80))
        ..setAnimation(animation: NCameraAnimation.easing),
    );
  }
}
