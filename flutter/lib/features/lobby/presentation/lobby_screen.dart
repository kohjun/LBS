// ignore_for_file: unnecessary_brace_in_string_interps, unnecessary_string_interpolations

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/services/socket_service.dart';
import '../../auth/data/auth_repository.dart';
import '../../game/presentation/game_ui_plugin.dart';
import '../../game/presentation/playable_area_painter_screen.dart';
import '../../home/data/session_repository.dart'
    show
        FantasyWarsTeamConfig,
        Session,
        SessionMember,
        sessionListProvider;
import '../providers/lobby_provider.dart';

class LobbyScreen extends ConsumerStatefulWidget {
  const LobbyScreen({
    super.key,
    required this.sessionId,
    this.gameType,
  });

  final String sessionId;
  final String? gameType;

  @override
  ConsumerState<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends ConsumerState<LobbyScreen> {
  Timer? _countdownTimer;
  StreamSubscription? _kickedSub;
  String _countdownText = '--:--:--';
  bool _startingGame = false;
  bool _savingFantasyWarsDuelConfig = false;
  bool _didNavigateToGame = false;
  bool _layoutSavedInThisVisit = false;

  @override
  void initState() {
    super.initState();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _updateCountdown();
    });

    _kickedSub = SocketService().onKicked.listen((_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('세션에서 강제 퇴장되었습니다.'),
          backgroundColor: Colors.red,
        ),
      );
      context.go('/');
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _kickedSub?.cancel();
    super.dispose();
  }

  void _updateCountdown() {
    if (!mounted) {
      return;
    }

    final expiresAt = ref.read(lobbyProvider(widget.sessionId)).sessionInfo?.expiresAt;
    if (expiresAt == null) {
      return;
    }

    final diff = expiresAt.difference(DateTime.now());
    setState(() {
      if (diff.isNegative) {
        _countdownText = '00:00:00';
      } else {
        final hours = diff.inHours.toString().padLeft(2, '0');
        final minutes = (diff.inMinutes % 60).toString().padLeft(2, '0');
        final seconds = (diff.inSeconds % 60).toString().padLeft(2, '0');
        _countdownText = '$hours:$minutes:$seconds';
      }
    });
  }

  Future<void> _confirmLeave() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('세션 나가기'),
        content: const Text('이 로비를 나가고 홈으로 돌아가시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('나가기'),
          ),
        ],
      ),
    );

    if (leave != true || !mounted) {
      return;
    }

    try {
      await ref.read(sessionListProvider.notifier).leaveSession(widget.sessionId);
      await ref
          .read(lobbyProvider(widget.sessionId).notifier)
          .releaseRealtimeResources(notifyServer: false);
      if (!mounted) {
        return;
      }
      context.go('/');
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showError('나가기 실패: $error');
    }
  }

  Future<void> _startGame() async {
    setState(() => _startingGame = true);
    try {
      await ref.read(lobbyProvider(widget.sessionId).notifier).startGame();
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showError(_friendlyStartError(error));
    } finally {
      if (mounted) {
        setState(() => _startingGame = false);
      }
    }
  }

  Future<void> _openBattlefieldEditor() async {
    final result = await Navigator.push<dynamic>(
      context,
      MaterialPageRoute(
        builder: (_) => PlayableAreaPainterScreen(sessionId: widget.sessionId),
      ),
    );

    if (!mounted || result == null) {
      return;
    }

    setState(() => _layoutSavedInThisVisit = true);
    await ref.read(lobbyProvider(widget.sessionId).notifier).refresh();
  }

  Future<void> _updateFantasyWarsDuelConfig({
    bool? bleRequired,
    int? bleEvidenceFreshnessMs,
  }) async {
    if (_savingFantasyWarsDuelConfig ||
        (bleRequired == null && bleEvidenceFreshnessMs == null)) {
      return;
    }

    setState(() => _savingFantasyWarsDuelConfig = true);
    try {
      await ref
          .read(lobbyProvider(widget.sessionId).notifier)
          .updateFantasyWarsDuelConfig(
            allowGpsFallbackWithoutBle:
                bleRequired == null ? null : !bleRequired,
            bleEvidenceFreshnessMs: bleEvidenceFreshnessMs,
          );
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showError('근접 결투 설정 저장 실패: $error');
    } finally {
      if (mounted) {
        setState(() => _savingFantasyWarsDuelConfig = false);
      }
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }

  String _friendlyStartError(Object error) {
    if (error is LobbyStartGameException) {
      switch (error.code) {
        case 'FANTASY_WARS_NOT_ENOUGH_PLAYERS':
          final required = error.details['required'];
          final current = error.details['current'];
          return '게임 시작 실패: 인원이 부족합니다. 현재 ${current ?? '?'}명 / 최소 ${required ?? '?'}명';
        case 'FANTASY_WARS_TEAM_ASSIGNMENT_REQUIRED':
          final unassigned = error.details['unassignedCount'];
          return '게임 시작 실패: 아직 길드가 정해지지 않은 인원이 ${unassigned ?? '?'}명 있습니다.';
        case 'FANTASY_WARS_TEAM_SIZE_TOO_SMALL':
          return '게임 시작 실패: 각 길드에 최소 2명 이상 있어야 합니다.';
        case 'FANTASY_WARS_PLAYABLE_AREA_REQUIRED':
          return '게임 시작 실패: 플레이 구역을 먼저 설정해주세요.';
        case 'FANTASY_WARS_CONTROL_POINTS_REQUIRED':
          return '게임 시작 실패: 점령지를 모두 배치해주세요.';
        case 'FANTASY_WARS_SPAWN_ZONES_REQUIRED':
          return '게임 시작 실패: 길드 시작 지점을 모두 배치해주세요.';
        case 'CONTROL_POINT_LOCATIONS_REQUIRED':
          return '게임 시작 실패: 점령지 좌표가 올바르지 않습니다.';
      }
    }

    return '게임 시작 실패: $error';
  }

  @override
  Widget build(BuildContext context) {
    final lobbyState = ref.watch(lobbyProvider(widget.sessionId));
    final authUser = ref.watch(authProvider).valueOrNull;
    final session = lobbyState.sessionInfo;
    final members = lobbyState.members;
    final myUserId = authUser?.id ?? '';
    final gameType = session?.gameType ?? widget.gameType ?? 'among_us';
    final isFantasyWars = _isFantasyWars(gameType);

    if (lobbyState.isGameStarted && !_didNavigateToGame) {
      _didNavigateToGame = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        context.go('/game/${widget.sessionId}?gameType=$gameType');
      });
    }

    final isHost = (session?.isHost ?? false) ||
        members.any((member) => member.userId == myUserId && member.role == 'host');
    final teams = _teamConfigsFor(session);
    final layoutStatus = _FantasyWarsLayoutStatus.fromSession(session, teams.length);
    final duelSettings = isFantasyWars
        ? _FantasyWarsDuelSettings.fromSession(session)
        : null;
    final startStatus = isFantasyWars
        ? _FantasyWarsStartStatus.fromSession(
            session: session,
            members: members,
            teams: teams,
          )
        : null;
    final minPlayers = isFantasyWars
        ? (startStatus?.requiredTotalPlayers ?? 9)
        : GameUiPluginRegistry.minPlayersFor(gameType);
    final fantasyWarsLayoutReady = layoutStatus.isReady || _layoutSavedInThisVisit;
    final canStart = isFantasyWars
        ? fantasyWarsLayoutReady && (startStatus?.isReady ?? false)
        : members.length >= minPlayers &&
            ((session?.playableArea?.length ?? 0) >= 3 || _layoutSavedInThisVisit);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          unawaited(_confirmLeave());
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(session?.name.isNotEmpty == true ? session!.name : '로비'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _confirmLeave,
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.copy),
              tooltip: '초대 코드 복사',
              onPressed: session == null
                  ? null
                  : () {
                      Clipboard.setData(ClipboardData(text: session.code));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('초대 코드가 복사되었습니다.')),
                      );
                    },
            ),
            IconButton(
              icon: const Icon(Icons.share),
              tooltip: '초대 코드 공유',
              onPressed: session == null
                  ? null
                  : () => Share.share('초대 코드 ${session.code}로 제 세션에 참가해주세요.'),
            ),
          ],
        ),
        body: lobbyState.isLoading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: () =>
                    ref.read(lobbyProvider(widget.sessionId).notifier).refresh(),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _SessionSummaryCard(
                      session: session,
                      countdownText: _countdownText,
                      gameType: gameType,
                      memberCount: members.length,
                    ),
                    const SizedBox(height: 16),
                    if (isFantasyWars) ...[
                      _FantasyWarsLayoutCard(status: layoutStatus),
                      const SizedBox(height: 16),
                      _FantasyWarsStartCard(status: startStatus!),
                      const SizedBox(height: 16),
                      _FantasyWarsDuelSettingsCard(
                        settings: duelSettings!,
                        isHost: isHost,
                        isSaving: _savingFantasyWarsDuelConfig,
                        onBleRequirementChanged: (value) {
                          unawaited(
                            _updateFantasyWarsDuelConfig(bleRequired: value),
                          );
                        },
                        onBleFreshnessChanged: (value) {
                          unawaited(
                            _updateFantasyWarsDuelConfig(
                              bleEvidenceFreshnessMs: value,
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 16),
                      _FantasyWarsTeamBoard(
                        teams: teams,
                        members: members,
                        myUserId: myUserId,
                        isHost: isHost,
                        sessionId: widget.sessionId,
                      ),
                    ] else ...[
                      _MemberList(
                        members: members,
                        myUserId: myUserId,
                        isHost: isHost,
                        sessionId: widget.sessionId,
                      ),
                    ],
                    const SizedBox(height: 16),
                    if (isHost) ...[
                      OutlinedButton.icon(
                        onPressed: _openBattlefieldEditor,
                        icon: const Icon(Icons.map_outlined),
                        label: Text(
                          isFantasyWars
                              ? (layoutStatus.isReady
                                  ? '전장 수정'
                                  : '전장 설정')
                              : ((session?.playableArea?.length ?? 0) >= 3
                                  ? '플레이 구역 수정'
                                  : '플레이 구역 설정'),
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (isFantasyWars && !fantasyWarsLayoutReady)
                        Text(
                          layoutStatus.missingSummary,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.orange),
                        ),
                      if (isFantasyWars && startStatus != null && !startStatus.isReady)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            startStatus.missingSummary,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.orange),
                          ),
                        ),
                      if (!isFantasyWars && (session?.playableArea?.length ?? 0) < 3)
                        const Text(
                          '게임을 시작하기 전에 플레이 구역을 설정해주세요.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.orange),
                        ),
                      if (!isFantasyWars && members.length < minPlayers)
                        Text(
                          '최소 $minPlayers명 이상 필요합니다.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.orange),
                        ),
                      const SizedBox(height: 8),
                      ElevatedButton.icon(
                        onPressed: canStart && !_startingGame ? _startGame : null,
                        icon: _startingGame
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.play_arrow),
                        label: Text(_startingGame ? '시작 중...' : '게임 시작'),
                      ),
                    ] else
                      const Text(
                        '길드를 선택한 뒤 호스트가 게임을 시작할 때까지 기다려주세요.',
                        textAlign: TextAlign.center,
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}

bool _isFantasyWars(String gameType) =>
    gameType == 'fantasy_wars_artifact' || gameType == 'fantasy_wars';

List<FantasyWarsTeamConfig> _teamConfigsFor(Session? session) {
  if (session?.fantasyWarsTeams.isNotEmpty == true) {
    return session!.fantasyWarsTeams;
  }

  return const [
    FantasyWarsTeamConfig(
      teamId: 'guild_alpha',
      displayName: '붉은 길드',
      color: '#DC2626',
    ),
    FantasyWarsTeamConfig(
      teamId: 'guild_beta',
      displayName: '푸른 길드',
      color: '#2563EB',
    ),
    FantasyWarsTeamConfig(
      teamId: 'guild_gamma',
      displayName: '초록 길드',
      color: '#16A34A',
    ),
  ];
}

class _FantasyWarsLayoutStatus {
  const _FantasyWarsLayoutStatus({
    required this.hasArea,
    required this.controlPointCount,
    required this.expectedControlPointCount,
    required this.spawnZoneCount,
    required this.expectedSpawnZoneCount,
  });

  final bool hasArea;
  final int controlPointCount;
  final int expectedControlPointCount;
  final int spawnZoneCount;
  final int expectedSpawnZoneCount;

  bool get isReady =>
      hasArea &&
      controlPointCount == expectedControlPointCount &&
      spawnZoneCount == expectedSpawnZoneCount;

  String get missingSummary {
    final parts = <String>[];
    if (!hasArea) {
      parts.add('플레이 구역');
    }
    if (controlPointCount != expectedControlPointCount) {
      parts.add('점령지 ${expectedControlPointCount}개');
    }
    if (spawnZoneCount != expectedSpawnZoneCount) {
      parts.add('길드 시작 지점 ${expectedSpawnZoneCount}개');
    }
    return parts.isEmpty
        ? '전장 설정이 완료되었습니다.'
        : '아직 필요한 항목: ${parts.join(', ')}';
  }

  static _FantasyWarsLayoutStatus fromSession(Session? session, int teamCount) {
    final expectedControlPointCount =
        (session?.gameConfig['controlPointCount'] as num?)?.toInt() ?? 5;
    return _FantasyWarsLayoutStatus(
      hasArea: (session?.playableArea?.length ?? 0) >= 3,
      controlPointCount: session?.fantasyWarsControlPoints.length ?? 0,
      expectedControlPointCount: expectedControlPointCount,
      spawnZoneCount: session?.fantasyWarsSpawnZones.length ?? 0,
      expectedSpawnZoneCount: teamCount,
    );
  }
}

class _FantasyWarsStartStatus {
  const _FantasyWarsStartStatus({
    required this.currentPlayers,
    required this.requiredTotalPlayers,
    required this.minimumPlayersPerTeam,
    required this.unassignedCount,
    required this.teamCounts,
    required this.undersizedTeams,
  });

  final int currentPlayers;
  final int requiredTotalPlayers;
  final int minimumPlayersPerTeam;
  final int unassignedCount;
  final Map<String, int> teamCounts;
  final List<FantasyWarsTeamConfig> undersizedTeams;

  bool get hasEnoughPlayers => currentPlayers >= requiredTotalPlayers;
  bool get hasUnassignedPlayers => unassignedCount > 0;
  bool get hasUndersizedTeams => undersizedTeams.isNotEmpty;
  bool get isReady =>
      hasEnoughPlayers && !hasUnassignedPlayers && !hasUndersizedTeams;

  String get missingSummary {
    final issues = <String>[];
    if (!hasEnoughPlayers) {
      issues.add('최소 $requiredTotalPlayers명 필요');
    }
    if (hasUnassignedPlayers) {
      issues.add('미배정 인원 $unassignedCount명');
    }
    if (hasUndersizedTeams) {
      issues.add(
        '${undersizedTeams.map((team) => '${team.displayName} ${teamCounts[team.teamId] ?? 0}/$minimumPlayersPerTeam').join(', ')}',
      );
    }

    return issues.isEmpty
        ? '시작 인원 조건이 충족되었습니다.'
        : '시작 전 확인: ${issues.join(' · ')}';
  }

  static _FantasyWarsStartStatus fromSession({
    required Session? session,
    required List<SessionMember> members,
    required List<FantasyWarsTeamConfig> teams,
  }) {
    final teamCounts = <String, int>{
      for (final team in teams) team.teamId: 0,
    };

    var unassignedCount = 0;
    for (final member in members) {
      final teamId = member.teamId;
      if (teamId == null || !teamCounts.containsKey(teamId)) {
        unassignedCount += 1;
        continue;
      }
      teamCounts[teamId] = (teamCounts[teamId] ?? 0) + 1;
    }

    final teamCount =
        (session?.gameConfig['teamCount'] as num?)?.toInt() ?? teams.length;
    final requiredTotalPlayers = (teamCount * 3) > 9 ? teamCount * 3 : 9;
    final undersizedTeams = teams
        .where((team) => (teamCounts[team.teamId] ?? 0) < 2)
        .toList(growable: false);

    return _FantasyWarsStartStatus(
      currentPlayers: members.length,
      requiredTotalPlayers: requiredTotalPlayers,
      minimumPlayersPerTeam: 2,
      unassignedCount: unassignedCount,
      teamCounts: teamCounts,
      undersizedTeams: undersizedTeams,
    );
  }
}

class _SessionSummaryCard extends StatelessWidget {
  const _SessionSummaryCard({
    required this.session,
    required this.countdownText,
    required this.gameType,
    required this.memberCount,
  });

  final Session? session;
  final String countdownText;
  final String gameType;
  final int memberCount;

  @override
  Widget build(BuildContext context) {
    final plugin = GameUiPluginRegistry.get(gameType);
    final gameLabel = plugin?.displayName ?? gameType;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              session?.name.isNotEmpty == true ? session!.name : '세션',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text('게임: $gameLabel'),
            Text('코드: ${session?.code ?? '------'}'),
            Text('인원: $memberCount명'),
            Text('남은 시간: $countdownText'),
          ],
        ),
      ),
    );
  }
}

class _FantasyWarsLayoutCard extends StatelessWidget {
  const _FantasyWarsLayoutCard({required this.status});

  final _FantasyWarsLayoutStatus status;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '전장 설정 상태',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _StatusChip(
                  label: status.hasArea ? '플레이 구역 완료' : '플레이 구역 필요',
                  ready: status.hasArea,
                ),
                _StatusChip(
                  label:
                      '점령지 ${status.controlPointCount}/${status.expectedControlPointCount}',
                  ready: status.controlPointCount == status.expectedControlPointCount,
                ),
                _StatusChip(
                  label:
                      '길드 시작 지점 ${status.spawnZoneCount}/${status.expectedSpawnZoneCount}',
                  ready: status.spawnZoneCount == status.expectedSpawnZoneCount,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              status.missingSummary,
              style: TextStyle(
                color: status.isReady ? Colors.green.shade700 : Colors.orange.shade800,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FantasyWarsStartCard extends StatelessWidget {
  const _FantasyWarsStartCard({required this.status});

  final _FantasyWarsStartStatus status;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '시작 준비 상태',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _StatusChip(
                  label: '인원 ${status.currentPlayers}/${status.requiredTotalPlayers}',
                  ready: status.hasEnoughPlayers,
                ),
                _StatusChip(
                  label: status.hasUnassignedPlayers
                      ? '미배정 ${status.unassignedCount}명'
                      : '길드 배정 완료',
                  ready: !status.hasUnassignedPlayers,
                ),
                _StatusChip(
                  label: status.hasUndersizedTeams
                      ? '길드 최소 ${status.minimumPlayersPerTeam}명 필요'
                      : '길드별 최소 인원 충족',
                  ready: !status.hasUndersizedTeams,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              status.missingSummary,
              style: TextStyle(
                color: status.isReady ? Colors.green.shade700 : Colors.orange.shade800,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '직업은 게임 시작 시 각 길드 인원 순서에 맞춰 랜덤 배정됩니다.',
              style: TextStyle(
                color: Colors.grey.shade700,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FantasyWarsDuelSettings {
  const _FantasyWarsDuelSettings({
    required this.bleRequired,
    required this.bleEvidenceFreshnessMs,
    required this.duelRangeMeters,
  });

  static const int defaultBleEvidenceFreshnessMs = 12000;
  static const int defaultDuelRangeMeters = 20;

  final bool bleRequired;
  final int bleEvidenceFreshnessMs;
  final int duelRangeMeters;

  static _FantasyWarsDuelSettings fromSession(Session? session) {
    final config = session?.gameConfig ?? const <String, dynamic>{};
    final allowGpsFallback = config['allowGpsFallbackWithoutBle'] as bool? ?? false;

    return _FantasyWarsDuelSettings(
      bleRequired: !allowGpsFallback,
      bleEvidenceFreshnessMs:
          (config['bleEvidenceFreshnessMs'] as num?)?.toInt() ??
              defaultBleEvidenceFreshnessMs,
      duelRangeMeters:
          (config['duelRangeMeters'] as num?)?.toInt() ??
              defaultDuelRangeMeters,
    );
  }
}

class _FantasyWarsDuelSettingsCard extends StatelessWidget {
  const _FantasyWarsDuelSettingsCard({
    required this.settings,
    required this.isHost,
    required this.isSaving,
    required this.onBleRequirementChanged,
    required this.onBleFreshnessChanged,
  });

  final _FantasyWarsDuelSettings settings;
  final bool isHost;
  final bool isSaving;
  final ValueChanged<bool> onBleRequirementChanged;
  final ValueChanged<int> onBleFreshnessChanged;

  @override
  Widget build(BuildContext context) {
    final freshnessOptions = <int>{
      8000,
      _FantasyWarsDuelSettings.defaultBleEvidenceFreshnessMs,
      20000,
      settings.bleEvidenceFreshnessMs,
    }.toList()
      ..sort();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '근접 결투 설정',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                if (isSaving)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              isHost
                  ? '호스트가 BLE 근접 확인 정책을 조정할 수 있습니다.'
                  : '이 경기는 아래 기준으로 결투 가능 여부를 판단합니다.',
              style: TextStyle(
                color: Colors.grey.shade700,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 12),
            SwitchListTile.adaptive(
              value: settings.bleRequired,
              onChanged: isHost && !isSaving ? onBleRequirementChanged : null,
              contentPadding: EdgeInsets.zero,
              title: const Text('BLE 확인 필수'),
              subtitle: Text(
                settings.bleRequired
                    ? 'BLE가 잡힌 적만 결투 후보에 표시됩니다.'
                    : 'BLE가 없어도 GPS 거리만 맞으면 결투를 허용합니다.',
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: settings.bleEvidenceFreshnessMs,
              decoration: const InputDecoration(
                labelText: 'BLE 증거 유지 시간',
                helperText: '근접 스캔이 잠깐 흔들려도 이 시간 안이면 결투를 허용합니다.',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final value in freshnessOptions)
                  DropdownMenuItem<int>(
                    value: value,
                    child: Text('${value ~/ 1000}초'),
                  ),
              ],
              onChanged: isHost && !isSaving
                  ? (value) {
                      if (value != null) {
                        onBleFreshnessChanged(value);
                      }
                    }
                  : null,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _StatusChip(
                  label: '결투 거리 ${settings.duelRangeMeters}m',
                  ready: true,
                ),
                _StatusChip(
                  label: '증거 유지 ${settings.bleEvidenceFreshnessMs ~/ 1000}초',
                  ready: settings.bleRequired,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    required this.ready,
  });

  final String label;
  final bool ready;

  @override
  Widget build(BuildContext context) {
    final color = ready ? Colors.green : Colors.orange;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color.shade700,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _FantasyWarsTeamBoard extends ConsumerWidget {
  const _FantasyWarsTeamBoard({
    required this.teams,
    required this.members,
    required this.myUserId,
    required this.isHost,
    required this.sessionId,
  });

  final List<FantasyWarsTeamConfig> teams;
  final List<SessionMember> members;
  final String myUserId;
  final bool isHost;
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unassignedMembers = members.where((member) {
      return !teams.any((team) => team.teamId == member.teamId);
    }).toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '길드',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            final cardWidth = constraints.maxWidth >= 960
                ? (constraints.maxWidth - 24) / 3
                : constraints.maxWidth >= 640
                    ? (constraints.maxWidth - 12) / 2
                    : constraints.maxWidth;

            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final team in teams)
                  SizedBox(
                    width: cardWidth,
                    child: _TeamCard(
                      team: team,
                      members: members
                          .where((member) => member.teamId == team.teamId)
                          .toList(growable: false),
                      allTeams: teams,
                      myUserId: myUserId,
                      isHost: isHost,
                      sessionId: sessionId,
                    ),
                  ),
                if (unassignedMembers.isNotEmpty)
                  SizedBox(
                    width: cardWidth,
                    child: _UnassignedCard(
                      members: unassignedMembers,
                      allTeams: teams,
                      myUserId: myUserId,
                      isHost: isHost,
                      sessionId: sessionId,
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _TeamCard extends ConsumerWidget {
  const _TeamCard({
    required this.team,
    required this.members,
    required this.allTeams,
    required this.myUserId,
    required this.isHost,
    required this.sessionId,
  });

  final FantasyWarsTeamConfig team;
  final List<SessionMember> members;
  final List<FantasyWarsTeamConfig> allTeams;
  final String myUserId;
  final bool isHost;
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color = _hexToColor(team.color);
    final myMember = members.where((member) => member.userId == myUserId).firstOrNull;
    final canJoin = myUserId.isNotEmpty && myMember == null;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: color, width: 5),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      team.displayName,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '${members.length}',
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (canJoin)
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () => _moveMember(
                      context,
                      ref,
                      userId: myUserId,
                      teamId: team.teamId,
                    ),
                    child: const Text('이 길드로 이동'),
                  ),
                )
              else if (myMember != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '현재 이 길드에 있습니다',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              if (members.isEmpty)
                Text(
                  '아직 팀원이 없습니다.',
                  style: TextStyle(color: Colors.grey.shade600),
                )
              else
                ...members.map(
                  (member) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _MemberTile(
                      member: member,
                      myUserId: myUserId,
                      isHost: isHost,
                      allTeams: allTeams,
                      sessionId: sessionId,
                      accentColor: color,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _moveMember(
    BuildContext context,
    WidgetRef ref, {
    required String userId,
    required String teamId,
  }) async {
    try {
      await ref.read(lobbyProvider(sessionId).notifier).moveMemberToTeam(userId, teamId);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('팀 이동 실패: $error'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}

class _UnassignedCard extends StatelessWidget {
  const _UnassignedCard({
    required this.members,
    required this.allTeams,
    required this.myUserId,
    required this.isHost,
    required this.sessionId,
  });

  final List<SessionMember> members;
  final List<FantasyWarsTeamConfig> allTeams;
  final String myUserId;
  final bool isHost;
  final String sessionId;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '미배정',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            ...members.map(
              (member) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _MemberTile(
                  member: member,
                  myUserId: myUserId,
                  isHost: isHost,
                  allTeams: allTeams,
                  sessionId: sessionId,
                  accentColor: Colors.grey.shade700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MemberTile extends ConsumerWidget {
  const _MemberTile({
    required this.member,
    required this.myUserId,
    required this.isHost,
    required this.allTeams,
    required this.sessionId,
    required this.accentColor,
  });

  final SessionMember member;
  final String myUserId;
  final bool isHost;
  final List<FantasyWarsTeamConfig> allTeams;
  final String sessionId;
  final Color accentColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isMe = member.userId == myUserId;
    final canManage = isHost && !member.isHost;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        dense: true,
        leading: CircleAvatar(
          backgroundColor: accentColor.withValues(alpha: 0.16),
          child: Text(
            member.nickname.isNotEmpty ? member.nickname[0].toUpperCase() : '?',
            style: TextStyle(color: accentColor),
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                '${member.nickname}${isMe ? ' (나)' : ''}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            if (member.isHost)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Text(
                  '호스트',
                  style: TextStyle(
                    color: Colors.blue,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
          ],
        ),
        subtitle: Text(member.role == 'host' ? '호스트' : '참가자'),
        trailing: canManage
            ? PopupMenuButton<String>(
                onSelected: (value) => _handleAction(context, ref, value),
                itemBuilder: (context) {
                  return [
                    for (final team in allTeams)
                      if (team.teamId != member.teamId)
                        PopupMenuItem(
                          value: 'move:${team.teamId}',
                          child: Text('${team.displayName}(으)로 이동'),
                        ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: 'kick',
                      child: Text('세션에서 강퇴'),
                    ),
                  ];
                },
              )
            : null,
      ),
    );
  }

  Future<void> _handleAction(BuildContext context, WidgetRef ref, String value) async {
    if (value == 'kick') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('참가자 강퇴'),
          content: Text('${member.nickname}님을 이 세션에서 내보내시겠습니까?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('취소'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('강퇴'),
            ),
          ],
        ),
      );

      if (confirmed != true) {
        return;
      }

      try {
        await ref.read(lobbyProvider(sessionId).notifier).kickMember(member.userId);
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('강퇴 실패: $error'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
      return;
    }

    if (value.startsWith('move:')) {
      final targetTeamId = value.substring('move:'.length);
      try {
        await ref
            .read(lobbyProvider(sessionId).notifier)
            .moveMemberToTeam(member.userId, targetTeamId);
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('팀 이동 실패: $error'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }
}

class _MemberList extends ConsumerWidget {
  const _MemberList({
    required this.members,
    required this.myUserId,
    required this.isHost,
    required this.sessionId,
  });

  final List<SessionMember> members;
  final String myUserId;
  final bool isHost;
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '참가자',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        ...members.map(
          (member) => Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: CircleAvatar(
                child: Text(
                  member.nickname.isNotEmpty ? member.nickname[0].toUpperCase() : '?',
                ),
              ),
              title: Text('${member.nickname}${member.userId == myUserId ? ' (나)' : ''}'),
              subtitle: Text(member.role == 'host' ? '호스트' : '참가자'),
              trailing: isHost && !member.isHost
                  ? IconButton(
                      icon: const Icon(Icons.person_remove, color: Colors.red),
                      onPressed: () async {
                        try {
                          await ref
                              .read(lobbyProvider(sessionId).notifier)
                              .kickMember(member.userId);
                        } catch (error) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('강퇴 실패: $error'),
                                backgroundColor: Colors.red,
                              ),
                            );
                          }
                        }
                      },
                    )
                  : null,
            ),
          ),
        ),
      ],
    );
  }
}

Color _hexToColor(String hex) {
  final normalized = hex.replaceFirst('#', '');
  final value = int.parse(normalized.length == 6 ? 'FF$normalized' : normalized, radix: 16);
  return Color(value);
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
