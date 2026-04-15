import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:wakelock_plus/wakelock_plus.dart'; // Task 2: 화면 꺼짐 방지

import '../../../core/services/socket_service.dart';
import '../../../core/services/sound_service.dart';
import '../data/game_models.dart';

final gameProvider =
    StateNotifierProvider.family<GameNotifier, AmongUsGameState, String>(
  (ref, sessionId) => GameNotifier(sessionId),
);

class GameNotifier extends StateNotifier<AmongUsGameState> {
  GameNotifier(this._sessionId) : super(const AmongUsGameState()) {
    _subscribeToEvents();
    if (_socket.isConnected) {
      _socket.requestGameState(_sessionId);
    }
  }

  final String _sessionId;
  final _socket = SocketService();
  final List<StreamSubscription> _subs = [];
  int _logIdCounter = 0;
  Timer? _meetingCooldownTimer;

  // ── [Stage 4] 위치 기반 미션 활성화 ─────────────────────────────────────────
  StreamSubscription<Position>? _missionLocationSub;

  /// 미션 활성화 반경 (미터). 이 안에 들어와야 수행하기 버튼이 켜집니다.
  static const double kActivationRadius = 15.0;

  /// Haversine 공식으로 두 GPS 좌표 사이의 거리(미터)를 반환합니다.
  static double _haversineMeters(
      double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0; // 지구 반지름 (m)
    final dLat = _rad(lat2 - lat1);
    final dLng = _rad(lng2 - lng1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_rad(lat1)) *
            math.cos(_rad(lat2)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  static double _rad(double deg) => deg * math.pi / 180;

  /// 현재 위치를 기준으로 반경 내 미션 ID 목록을 갱신합니다.
  void _onLocationForMissions(Position pos) {
    final candidates = state.missions
        .where((m) => m.hasLocation && !m.isCompleted && !m.isFake)
        .toList();

    if (candidates.isEmpty) return;

    final nearby = candidates
        .where((m) => _haversineMeters(
              pos.latitude, pos.longitude, m.lat!, m.lng!) <= kActivationRadius)
        .map((m) => m.id)
        .toList();

    // 변경이 없으면 불필요한 리빌드 방지
    final current = state.nearbyMissionIds;
    final changed = nearby.length != current.length ||
        nearby.any((id) => !current.contains(id));
    if (!changed) return;

    state = state.copyWith(nearbyMissionIds: nearby);
  }

  /// GPS 구독을 시작합니다. 이미 실행 중이면 무시합니다.
  void _startMissionLocationTracking() {
    if (_missionLocationSub != null) return;
    _missionLocationSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 3, // 3m 이상 이동 시에만 재판정
      ),
    ).listen(_onLocationForMissions, onError: (_) {});
  }
  // ─────────────────────────────────────────────────────────────────────────────

  String _nextLogId() =>
      '${DateTime.now().millisecondsSinceEpoch}_${_logIdCounter++}';

  void _subscribeToEvents() {
    _subs.add(_socket.onConnectionChange.listen((connected) {
      if (connected) {
        _socket.requestGameState(_sessionId);
      }
    }));

    _subs.add(_socket.onGameStateUpdate.listen((data) {
      final role = data['role'] as String?;
      final team = data['team'] as String?;
      final recoveredRole = role != null && team != null
          ? GameRole(
              role: role,
              team: team,
              impostors:
                  (data['impostors'] as List?)?.whereType<String>().toList() ??
                      const [],
            )
          : null;

      state = state.copyWith(
        isStarted: (data['status'] as String? ?? 'none') != 'none',
        totalPlayers: data['aliveCount'] as int? ?? state.totalPlayers,
        myRole: recoveredRole ?? state.myRole,
        shouldNavigateToRole: recoveredRole != null && state.myRole == null
            ? true
            : state.shouldNavigateToRole,
      );
    }));

    _subs.add(_socket.onGameEvent(SocketService.gameStarted).listen((data) {
      // [Task 2] 게임 시작 시 WakeLock 활성화 + 효과음
      WakelockPlus.enable();
      SoundService().playGameStart();
      state = state.copyWith(
        isStarted: true,
        totalPlayers: data['playerCount'] as int? ?? 0,
      );
    }));

    _subs
        .add(_socket.onGameEvent(SocketService.gameRoleAssigned).listen((data) {
      state = state.copyWith(
        myRole: GameRole.fromMap(data),
        shouldNavigateToRole: true,
      );
    }));

    _subs.add(
      _socket.onGameEvent(SocketService.gameMeetingStarted).listen((data) {
        state = state.copyWith(
          meetingPhase: 'discussion',
          meetingRemaining: data['discussionTime'] as int? ?? 90,
          totalVoted: 0,
          preVoteCount: 0,
          voteResult: null,
          shouldNavigateToMeeting: true,
          isMeetingCoolingDown: false,
        );
      }),
    );

    _subs.add(_socket.onGameEvent(SocketService.gameMeetingTick).listen((data) {
      state = state.copyWith(
        meetingPhase: data['phase'] as String,
        meetingRemaining: data['remaining'] as int,
      );
    }));

    _subs.add(_socket.onGameEvent(SocketService.gameVotingStarted).listen((_) {
      state = state.copyWith(meetingPhase: 'voting');
    }));

    _subs.add(
      _socket.onGameEvent(SocketService.gamePreVoteSubmitted).listen((data) {
        state = state.copyWith(
          preVoteCount: data['totalPreVotes'] as int? ?? 0,
          totalPlayers: data['totalPlayers'] as int? ?? state.totalPlayers,
        );
      }),
    );

    _subs.add(
      _socket.onGameEvent(SocketService.gameVoteSubmitted).listen((data) {
        state = state.copyWith(
          totalVoted: data['totalVotes'] as int? ?? 0,
          totalPlayers: data['totalPlayers'] as int? ?? state.totalPlayers,
        );
      }),
    );

    _subs.add(_socket.onGameEvent(SocketService.gameVoteResult).listen((data) {
      state = state.copyWith(
        meetingPhase: 'result',
        voteResult: VoteResult.fromMap(data),
      );
    }));

    _subs.add(_socket.onGameEvent(SocketService.gameMeetingEnded).listen((_) {
      state = state.copyWith(
        meetingPhase: 'none',
        isMeetingCoolingDown: true,
      );
      // 30초 후 쿨타임 해제
      _meetingCooldownTimer?.cancel();
      _meetingCooldownTimer = Timer(const Duration(seconds: 30), () {
        state = state.copyWith(isMeetingCoolingDown: false);
      });
    }));

    // ── 사보타지 이벤트 ───────────────────────────────────────────────────
    _subs.add(
      _socket.onGameEvent(SocketService.gameSabotageActive).listen((data) {
        final missionId = data['missionId'] as String?;
        if (missionId == null) return;
        final updated = state.myMissions.map((m) {
          if (m.id == missionId) return m.copyWith(isSabotaged: true);
          return m;
        }).toList();
        state = state.copyWith(myMissions: updated);
      }),
    );

    _subs.add(
      _socket.onGameEvent(SocketService.gameSabotageFixed).listen((data) {
        final missionId = data['missionId'] as String?;
        if (missionId == null) return;
        final updated = state.myMissions.map((m) {
          if (m.id == missionId) return m.copyWith(isSabotaged: false);
          return m;
        }).toList();
        state = state.copyWith(myMissions: updated);
      }),
    );

    _subs.add(_socket.onGameEvent(SocketService.gameAiMessage).listen((data) {
      final log = ChatLog(
        id: _nextLogId(),
        type: ChatLogType.aiAnnounce,
        message: data['message'] as String,
        timestamp: DateTime.now(),
      );
      state = state.copyWith(chatLogs: [...state.chatLogs, log]);
    }));

    _subs.add(_socket.onGameEvent(SocketService.gameAiReply).listen((data) {
      final isError = data['isError'] as bool? ?? false;
      final message = data['answer'] as String? ?? 'Failed to load AI response.';

      final log = ChatLog(
        id: _nextLogId(),
        type: isError ? ChatLogType.system : ChatLogType.aiReply,
        message: message,
        timestamp: DateTime.now(),
      );
      state = state.copyWith(chatLogs: [...state.chatLogs, log]);
    }));

    _subs.add(
      _socket.onGameEvent(SocketService.gameMissionProgress).listen((data) {
        final missionId = data['missionId'] as String?;
        final completed = (data['completed'] as num?)?.toInt() ?? 0;
        final total = (data['total'] as num?)?.toInt() ?? 0;
        final percent = (data['percent'] as num?)?.toDouble() ?? 0;
        final hasMission = missionId != null &&
            state.missions.any((mission) => mission.id == missionId);

        final updatedMissions = missionId == null
            ? state.missions
            : [
                ...state.missions.map(
                  (mission) => mission.id == missionId
                      ? GameMission(
                          id: mission.id,
                          title: mission.title,
                          zone: mission.zone,
                          type: mission.type,
                          status: completed >= total && total > 0
                              ? 'completed'
                              : 'in_progress',
                          isFake: mission.isFake,
                        )
                      : mission,
                ),
                if (!hasMission)
                  GameMission(
                    id: missionId,
                    title: data['title'] as String? ?? missionId,
                    zone: data['zone'] as String? ?? '',
                    type: data['type'] as String? ?? 'mini_game',
                    status: completed >= total && total > 0
                        ? 'completed'
                        : 'in_progress',
                    isFake: data['isFake'] as bool? ?? false,
                  ),
              ];

        state = state.copyWith(
          missions: updatedMissions,
          missionProgress: {
            'completed': completed,
            'total': total,
            'percent': percent,
          },
        );

        // [Stage 4] 좌표가 있는 미션이 수신되면 GPS 추적 자동 시작
        final hasLocatedMission =
            updatedMissions.any((m) => m.hasLocation && !m.isCompleted);
        if (hasLocatedMission) _startMissionLocationTracking();
      }),
    );

    // [4단계] 서버에서 전체 태스크 진행도 수신
    _subs.add(_socket.onGameEvent(SocketService.gameTaskProgress).listen((data) {
      final progress = (data['progress'] as num?)?.toDouble() ?? 0.0;
      state = state.copyWith(totalTaskProgress: progress.clamp(0.0, 1.0));
    }));

    _subs.add(_socket.onGameEvent(SocketService.gameOver).listen((data) {
      // [Task 2] 게임 종료 시 WakeLock 해제 + 효과음
      WakelockPlus.disable();
      SoundService().playGameOver();
      state = state.copyWith(
        gameOverWinner: data['winner'] as String,
      );
    }));

    _subs.add(_socket.onGameEvent(SocketService.gameKillConfirmed).listen((_) {
      // Reserved for local self-state updates when needed.
    }));

    // 게임 시작 시 서버에서 미션 목록 수신
    _subs.add(_socket.onGameEvent(SocketService.gameMissionsAssigned).listen((data) {
      final rawList = data['missions'] as List? ?? [];
      final gameMissions = rawList
          .whereType<Map>()
          .map((m) => GameMission.fromMap(Map<String, dynamic>.from(m)))
          .toList();

      // GameMission → Mission 변환 (미니게임 실행용)
      final myMissions = gameMissions.map((gm) {
        final missionType =
            gm.hasLocation ? MissionType.location : MissionType.qr;
        return Mission(
          id: gm.id,
          title: gm.title,
          description: gm.isFake ? '[임포스터 가짜 미션] ${gm.title}' : gm.title,
          type: missionType,
          status: MissionStatus.locked,
          minigameId: _resolveMiniGameId(gm.title),
          targetLatitude: gm.lat,
          targetLongitude: gm.lng,
          radius: 15.0,
        );
      }).toList();

      state = state.copyWith(missions: gameMissions, myMissions: myMissions);

      final hasLocatedMission =
          gameMissions.any((m) => m.hasLocation && !m.isCompleted);
      if (hasLocatedMission) _startMissionLocationTracking();
    }));
  }

  /// 미션 제목으로 적절한 미니게임 ID를 반환합니다.
  static String _resolveMiniGameId(String title) {
    if (title.contains('전선') || title.contains('수리')) return 'wire_fix';
    if (title.contains('데이터') || title.contains('업로드')) return 'card_swipe';
    if (title.contains('카드') || title.contains('스와이프')) return 'card_swipe';
    return 'card_swipe'; // 기본 미니게임
  }

  void startGame() => _socket.startGame(_sessionId);

  void sendKill(String targetUserId) =>
      _socket.sendKill(_sessionId, targetUserId);

  void sendEmergency([Function(Map)? onResult]) =>
      _socket.sendEmergencyMeeting(_sessionId, onResult);

  void sendReport(String bodyId) => _socket.sendReport(_sessionId, bodyId);

  void sendVote(String targetId, Function(Map) onResult) =>
      _socket.sendVote(_sessionId, targetId, onResult);

  // ── [1단계] 미니게임 미션 관리 ────────────────────────────────────────────────

  List<Mission> get myMissions => state.myMissions;

  /// 테스트용 미션 할당: QR 미션 1개 + 위치 기반 미션 1개.
  void assignInitialMissions() {
    final missions = [
      const Mission(
        id: 'test_qr_01',
        title: '전선 수리',
        description: 'QR 코드를 스캔하여 전선 수리 미니게임을 시작하세요.',
        type: MissionType.qr,
        status: MissionStatus.locked,
        minigameId: 'wire_fix',
      ),
      const Mission(
        id: 'test_loc_01',
        title: '데이터 업로드',
        description: '지정된 구역으로 이동하여 데이터를 업로드하세요.',
        type: MissionType.location,
        status: MissionStatus.locked,
        minigameId: 'card_swipe',
        // 테스트 좌표 – 실제 배포 시 서버에서 수신한 값으로 대체하세요.
        targetLatitude: 37.5665,
        targetLongitude: 126.9780,
        radius: 30.0,
      ),
    ];
    state = state.copyWith(myMissions: missions);
  }

  /// GPS 위치 갱신 시 호출 – 위치 기반 미션의 반경 진입 여부를 판별합니다.
  void updatePlayerLocation(double lat, double lng) {
    final updated = state.myMissions.map((m) {
      if (m.type != MissionType.location ||
          m.status == MissionStatus.completed ||
          m.targetLatitude == null ||
          m.targetLongitude == null) {
        return m;
      }
      final dist = _haversineMeters(lat, lng, m.targetLatitude!, m.targetLongitude!);
      final isNear = dist <= m.radius;
      if (isNear && m.status == MissionStatus.locked) {
        return m.copyWith(status: MissionStatus.ready);
      }
      if (!isNear && m.status == MissionStatus.ready) {
        return m.copyWith(status: MissionStatus.locked);
      }
      return m;
    }).toList();

    final changed = updated.any((m) {
      final orig = state.myMissions.firstWhere((o) => o.id == m.id);
      return orig.status != m.status;
    });
    if (changed) state = state.copyWith(myMissions: updated);
  }

  /// 미션을 완료 처리하고 서버에 알립니다.
  void completeMission(String missionId) {
    // 로컬 미니게임 미션 완료 처리
    final updated = state.myMissions.map((m) {
      if (m.id == missionId) return m.copyWith(status: MissionStatus.completed);
      return m;
    }).toList();
    state = state.copyWith(myMissions: updated);

    // 서버 동기화 (기존 GameMission도 완료 처리)
    _socket.sendMissionComplete(_sessionId, missionId);
  }

  /// 임포스터가 특정 미션에 사보타지를 발동합니다.
  void triggerSabotage(String missionId) {
    _socket.sendTriggerSabotage(_sessionId, missionId);
  }

  /// 크루원이 사보타지 수리 미니게임을 클리어하면 호출됩니다.
  void fixSabotage(String missionId) {
    final updated = state.myMissions.map((m) {
      if (m.id == missionId) return m.copyWith(isSabotaged: false);
      return m;
    }).toList();
    state = state.copyWith(myMissions: updated);
    _socket.sendFixSabotage(_sessionId, missionId);
  }

  /// GameMeetingScreen 이동 후 호출하여 플래그를 리셋합니다.
  void resetMeetingNavigation() {
    state = state.copyWith(shouldNavigateToMeeting: false);
  }

  /// 긴급 회의를 소집합니다.
  void callMeeting([Function(Map)? callback]) {
    state = state.copyWith(isMeetingCoolingDown: true);
    _socket.sendEmergencyMeeting(_sessionId, callback);
  }

  /// 호스트가 설정한 플레이 가능 영역 폴리곤을 상태에 저장합니다.
  /// null을 전달하면 이탈 경고 판정이 비활성화됩니다.
  /// 유효한 폴리곤이 전달되면 위치 기반 미션 활성화 GPS 추적도 함께 시작합니다.
  void setPlayableArea(List<Map<String, double>>? area) {
    state = state.copyWith(playableArea: area);
    if (area != null && area.length >= 3) {
      _startMissionLocationTracking();
    }
  }

  void resetRoleNavigation() {
    state = state.copyWith(shouldNavigateToRole: false);
  }

  void askAI(String question) {
    final myLog = ChatLog(
      id: _nextLogId(),
      type: ChatLogType.myQuestion,
      message: question,
      timestamp: DateTime.now(),
    );
    state = state.copyWith(chatLogs: [...state.chatLogs, myLog]);

    _socket.sendAiQuestion(_sessionId, question, (res) {
      if (res['ok'] == true) return;

      final errLog = ChatLog(
        id: _nextLogId(),
        type: ChatLogType.system,
        message: 'Failed to send: ${res['error']}',
        timestamp: DateTime.now(),
      );
      state = state.copyWith(chatLogs: [...state.chatLogs, errLog]);
    });
  }

  @override
  void dispose() {
    // [Task 2] Provider 해제 시 WakeLock 반드시 해제 (메모리 누수 방지)
    WakelockPlus.disable();
    _meetingCooldownTimer?.cancel();
    for (final sub in _subs) {
      sub.cancel();
    }
    _missionLocationSub?.cancel(); // [Stage 4] 미션 GPS 구독 해제
    super.dispose();
  }
}
