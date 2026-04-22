// lib/features/lobby/providers/lobby_provider.dart

import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/mediasoup_audio_service.dart';
import '../../../core/services/socket_service.dart';
import '../../home/data/session_repository.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 로비 상태
// ─────────────────────────────────────────────────────────────────────────────

class LobbyState {
  final List<SessionMember> members;
  final bool isGameStarted;
  final Session? sessionInfo;
  final bool isLoading;
  final Map<String, dynamic>? gameStartPayload;
  /// 현재 말하고 있는 userId 집합
  final Set<String> speakingUserIds;

  const LobbyState({
    this.members = const [],
    this.isGameStarted = false,
    this.sessionInfo,
    this.isLoading = true,
    this.gameStartPayload,
    this.speakingUserIds = const {},
  });

  LobbyState copyWith({
    List<SessionMember>? members,
    bool? isGameStarted,
    Session? sessionInfo,
    bool? isLoading,
    Map<String, dynamic>? gameStartPayload,
    Set<String>? speakingUserIds,
  }) {
    return LobbyState(
      members: members ?? this.members,
      isGameStarted: isGameStarted ?? this.isGameStarted,
      sessionInfo: sessionInfo ?? this.sessionInfo,
      isLoading: isLoading ?? this.isLoading,
      gameStartPayload: gameStartPayload ?? this.gameStartPayload,
      speakingUserIds: speakingUserIds ?? this.speakingUserIds,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 로비 Notifier
// ─────────────────────────────────────────────────────────────────────────────

class LobbyNotifier extends StateNotifier<LobbyState> {
  LobbyNotifier(this._sessionId, this._ref) : super(const LobbyState()) {
    _init();
  }

  final String _sessionId;
  final Ref _ref;

  final _socket = SocketService();
  final _audio = MediaSoupAudioService();

  StreamSubscription? _memberJoinSub;
  StreamSubscription? _memberLeftSub;
  StreamSubscription? _memberUpdatedSub;
  StreamSubscription? _kickedSub;
  StreamSubscription? _gameStartedSub;
  StreamSubscription? _connectionSub;
  StreamSubscription? _voiceSpeakingSub;

  Future<void> _init() async {
    // 1. 소켓 연결
    try {
      await _socket.connect();
      _socket.joinSession(_sessionId);
    } catch (e) {
      debugPrint('[Lobby] Socket connect failed: $e');
    }

    // 2. 소켓 이벤트 구독
    _bindSocketStreams();

    // 3. 세션 정보 로드
    await _loadSession();
  }

  void _bindSocketStreams() {
    _memberJoinSub = _socket.onMemberJoined.listen((data) {
      final userId = data['userId'] as String? ?? '';
      final nickname = data['nickname'] as String? ?? userId;
      final role = data['role'] as String? ?? 'member';
      if (userId.isEmpty) return;

      final exists = state.members.any((m) => m.userId == userId);
      if (!exists) {
        state = state.copyWith(
          members: [
            ...state.members,
            SessionMember(
              userId: userId,
              nickname: nickname,
              isHost: role == 'host',
              role: role,
              teamId: data['teamId'] as String?,
            ),
          ],
        );
      }
    });

    _memberLeftSub = _socket.onMemberLeft.listen((data) {
      final userId = data['userId'] as String? ?? '';
      if (userId.isEmpty) return;
      state = state.copyWith(
        members: state.members.where((m) => m.userId != userId).toList(),
      );
    });

    _memberUpdatedSub = _socket.onMemberUpdated.listen((data) {
      final userId = data['userId'] as String? ?? '';
      if (userId.isEmpty) return;

      state = state.copyWith(
        members: state.members.map((member) {
          if (member.userId != userId) {
            return member;
          }

          return SessionMember(
            userId: member.userId,
            nickname: member.nickname,
            avatarUrl: member.avatarUrl,
            isHost: member.isHost,
            role: member.role,
            teamId: data['teamId'] as String? ?? member.teamId,
            sharingEnabled: member.sharingEnabled,
            latitude: member.latitude,
            longitude: member.longitude,
            battery: member.battery,
            status: member.status,
          );
        }).toList(),
      );
    });

    _kickedSub = _socket.onKicked.listen((_) {
      // kicked 이벤트 수신 시 isGameStarted = false 로 유지하고 UI가 뒤로 이동
      // LobbyScreen에서 구독하여 처리
    });

    _gameStartedSub = _socket.onGameStarted.listen((data) {
      state = state.copyWith(
        isGameStarted: true,
        gameStartPayload: data,
      );
    });

    _connectionSub = _socket.onConnectionChange.listen((connected) {
      if (connected) {
        _socket.joinSession(_sessionId);
      }
    });

    _voiceSpeakingSub = _socket.onVoiceSpeaking.listen((data) {
      final userId = data['userId'] as String? ?? '';
      final isSpeaking = data['isSpeaking'] as bool? ?? false;
      if (userId.isEmpty) return;

      final current = Set<String>.from(state.speakingUserIds);
      if (isSpeaking) {
        current.add(userId);
      } else {
        current.remove(userId);
      }
      state = state.copyWith(speakingUserIds: current);
    });
  }

  Future<void> _loadSession() async {
    try {
      final repo = _ref.read(sessionRepositoryProvider);
      final session = await repo.getSession(_sessionId);
      if (!mounted) return;
      state = state.copyWith(
        sessionInfo: session,
        members: session.members,
        isLoading: false,
      );
    } catch (e) {
      debugPrint('[Lobby] Failed to load session: $e');
      if (!mounted) return;
      state = state.copyWith(isLoading: false);
    }
  }

  Future<void> refresh() => _loadSession();

  Future<void> startGame() async {
    final repo = _ref.read(sessionRepositoryProvider);
    try {
      await repo.startGame(_sessionId);
      return;
    } on DioException catch (error) {
      debugPrint('[Lobby] startGame failed: $error');

      // 타임아웃/연결 오류는 서버가 실제로 처리했을 수 있다.
      // 소켓 이벤트(game:started)로 게임 시작 여부를 확인하고자
      // 최대 3초까지 대기한다.
      const pollInterval = Duration(milliseconds: 300);
      const pollLimit = 10; // 300ms × 10 = 3s
      for (var i = 0; i < pollLimit; i++) {
        await Future<void>.delayed(pollInterval);
        if (state.isGameStarted) return;
      }

      if (state.isGameStarted) return;
      rethrow;
    } catch (e) {
      debugPrint('[Lobby] startGame failed: $e');
      // 다른 오류도 소켓 이벤트가 도착했으면 성공으로 간주
      if (state.isGameStarted) return;
      rethrow;
    }
  }

  Future<void> kickMember(String userId) async {
    await _ref.read(sessionRepositoryProvider).kickMember(_sessionId, userId);
  }

  Future<void> moveMemberToTeam(String userId, String teamId) async {
    await _ref
        .read(sessionRepositoryProvider)
        .moveMemberToTeam(_sessionId, userId, teamId);
  }

  Future<void> releaseRealtimeResources({
    bool notifyServer = true,
  }) async {
    await _audio.leaveSession();
    _socket.leaveSession(
      sessionId: _sessionId,
      notifyServer: notifyServer,
    );
  }

  @override
  void dispose() {
    _memberJoinSub?.cancel();
    _memberLeftSub?.cancel();
    _memberUpdatedSub?.cancel();
    _kickedSub?.cancel();
    _gameStartedSub?.cancel();
    _connectionSub?.cancel();
    _voiceSpeakingSub?.cancel();
    super.dispose();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Provider
// ─────────────────────────────────────────────────────────────────────────────

final lobbyProvider =
    StateNotifierProvider.autoDispose.family<LobbyNotifier, LobbyState, String>(
  (ref, sessionId) => LobbyNotifier(sessionId, ref),
);
