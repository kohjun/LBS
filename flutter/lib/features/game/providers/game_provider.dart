import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/socket_service.dart';
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
      state = state.copyWith(meetingPhase: 'none');
    }));

    _subs.add(_socket.onGameEvent(SocketService.gameAiMessage).listen((data) {
      final log = ChatLog(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        type: ChatLogType.aiAnnounce,
        message: data['message'] as String,
        timestamp: DateTime.now(),
      );
      state = state.copyWith(chatLogs: [...state.chatLogs, log]);
    }));

    _subs.add(_socket.onGameEvent(SocketService.gameAiReply).listen((data) {
      final isError = data['isError'] as bool? ?? false;
      final message = data['answer'] as String? ?? 'AI 응답을 불러오지 못했습니다.';

      final log = ChatLog(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
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
      }),
    );

    _subs.add(_socket.onGameEvent(SocketService.gameOver).listen((data) {
      state = state.copyWith(
        gameOverWinner: data['winner'] as String,
      );
    }));

    _subs.add(_socket.onGameEvent(SocketService.gameKillConfirmed).listen((_) {
      // Reserved for local self-state updates when needed.
    }));
  }

  void startGame() => _socket.startGame(_sessionId);

  void sendKill(String targetUserId) =>
      _socket.sendKill(_sessionId, targetUserId);

  void sendEmergency([Function(Map)? onResult]) =>
      _socket.sendEmergencyMeeting(_sessionId, onResult);

  void sendReport(String bodyId) => _socket.sendReport(_sessionId, bodyId);

  void sendVote(String targetId, Function(Map) onResult) =>
      _socket.sendVote(_sessionId, targetId, onResult);

  void completeMission(String missionId) =>
      _socket.sendMissionComplete(_sessionId, missionId);

  void resetRoleNavigation() {
    state = state.copyWith(shouldNavigateToRole: false);
  }

  void askAI(String question) {
    final myLog = ChatLog(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: ChatLogType.myQuestion,
      message: question,
      timestamp: DateTime.now(),
    );
    state = state.copyWith(chatLogs: [...state.chatLogs, myLog]);

    _socket.sendAiQuestion(_sessionId, question, (res) {
      if (res['ok'] == true) return;

      final errLog = ChatLog(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        type: ChatLogType.system,
        message: '질문 전송 실패: ${res['error']}',
        timestamp: DateTime.now(),
      );
      state = state.copyWith(chatLogs: [...state.chatLogs, errLog]);
    });
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    super.dispose();
  }
}
