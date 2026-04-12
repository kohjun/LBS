// lib/features/lobby/providers/lobby_provider.dart

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  const LobbyState({
    this.members = const [],
    this.isGameStarted = false,
    this.sessionInfo,
    this.isLoading = true,
    this.gameStartPayload,
  });

  LobbyState copyWith({
    List<SessionMember>? members,
    bool? isGameStarted,
    Session? sessionInfo,
    bool? isLoading,
    Map<String, dynamic>? gameStartPayload,
  }) {
    return LobbyState(
      members:          members         ?? this.members,
      isGameStarted:    isGameStarted   ?? this.isGameStarted,
      sessionInfo:      sessionInfo     ?? this.sessionInfo,
      isLoading:        isLoading       ?? this.isLoading,
      gameStartPayload: gameStartPayload ?? this.gameStartPayload,
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

  StreamSubscription? _memberJoinSub;
  StreamSubscription? _memberLeftSub;
  StreamSubscription? _kickedSub;
  StreamSubscription? _gameStartedSub;
  StreamSubscription? _connectionSub;

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
      final userId   = data['userId']   as String? ?? '';
      final nickname = data['nickname'] as String? ?? userId;
      final role     = data['role']     as String? ?? 'member';
      if (userId.isEmpty) return;

      final exists = state.members.any((m) => m.userId == userId);
      if (!exists) {
        state = state.copyWith(
          members: [
            ...state.members,
            SessionMember(
              userId:   userId,
              nickname: nickname,
              isHost:   role == 'host',
              role:     role,
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

    _kickedSub = _socket.onKicked.listen((_) {
      // kicked 이벤트 수신 시 isGameStarted = false 로 유지하고 UI가 뒤로 이동
      // LobbyScreen에서 구독하여 처리
    });

    _gameStartedSub = _socket.onGameStarted.listen((data) {
      state = state.copyWith(
        isGameStarted:    true,
        gameStartPayload: data,
      );
    });

    _connectionSub = _socket.onConnectionChange.listen((connected) {
      if (connected) {
        _socket.joinSession(_sessionId);
      }
    });
  }

  Future<void> _loadSession() async {
    try {
      final repo    = _ref.read(sessionRepositoryProvider);
      final session = await repo.getSession(_sessionId);
      state = state.copyWith(
        sessionInfo: session,
        members:     session.members,
        isLoading:   false,
      );
    } catch (e) {
      debugPrint('[Lobby] Failed to load session: $e');
      state = state.copyWith(isLoading: false);
    }
  }

  Future<void> refresh() => _loadSession();

  Future<void> startGame() async {
    try {
      final repo = _ref.read(sessionRepositoryProvider);
      await repo.startGame(_sessionId);
    } catch (e) {
      debugPrint('[Lobby] startGame failed: $e');
      rethrow;
    }
  }

  Future<void> kickMember(String userId) async {
    await _ref.read(sessionRepositoryProvider).kickMember(_sessionId, userId);
  }

  Future<void> promoteToAdmin(String userId) async {
    await _ref.read(sessionRepositoryProvider).updateMemberRole(
      _sessionId,
      userId,
      'admin',
    );
    state = state.copyWith(
      members: state.members.map((m) {
        if (m.userId == userId) {
          return SessionMember(
            userId:         m.userId,
            nickname:       m.nickname,
            avatarUrl:      m.avatarUrl,
            isHost:         m.isHost,
            role:           'admin',
            sharingEnabled: m.sharingEnabled,
          );
        }
        return m;
      }).toList(),
    );
  }

  @override
  void dispose() {
    _memberJoinSub?.cancel();
    _memberLeftSub?.cancel();
    _kickedSub?.cancel();
    _gameStartedSub?.cancel();
    _connectionSub?.cancel();
    super.dispose();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Provider
// ─────────────────────────────────────────────────────────────────────────────

final lobbyProvider = StateNotifierProvider.family<LobbyNotifier, LobbyState, String>(
  (ref, sessionId) => LobbyNotifier(sessionId, ref),
);
