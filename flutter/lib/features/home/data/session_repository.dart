// lib/features/home/data/session_repository.dart

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 데이터 모델
// ─────────────────────────────────────────────────────────────────────────────

class SessionMember {
  final String userId;
  final String nickname;
  final String? avatarUrl;
  final bool isHost;
  final String role; // 'host' | 'admin' | 'member'
  final bool sharingEnabled;
  final double? latitude;
  final double? longitude;
  final int? battery;
  final String status; // 'moving' | 'idle'

  const SessionMember({
    required this.userId,
    required this.nickname,
    this.avatarUrl,
    required this.isHost,
    this.role = 'member',
    this.sharingEnabled = true,
    this.latitude,
    this.longitude,
    this.battery,
    this.status = 'idle',
  });

  factory SessionMember.fromMap(Map<String, dynamic> m) {
    // GET /sessions/:id 응답: 위치 데이터는 lastLocation에 중첩
    final loc = m['lastLocation'] as Map<String, dynamic>?;
    return SessionMember(
      userId: m['user_id'] as String,
      nickname: m['nickname'] as String,
      avatarUrl: m['avatar_url'] as String?,
      isHost: m['is_host'] as bool? ?? false,
      role: m['role'] as String? ?? 'member',
      sharingEnabled: m['sharing_enabled'] as bool? ?? true,
      latitude: (loc?['lat'] as num?)?.toDouble(),
      longitude: (loc?['lng'] as num?)?.toDouble(),
      battery: loc?['battery'] as int?,
      status: loc?['status'] as String? ?? 'idle',
    );
  }
}

class Session {
  final String id;
  final String name;
  final String code;
  final bool isHost;
  final int memberCount;
  final List<SessionMember> members;
  final DateTime createdAt;
  final DateTime? expiresAt; // 추가됨: 세션 만료 시간
  final List<String> activeModules;
  final Map<String, dynamic> moduleConfigs;
  final String gameStatus; // 'lobby' | 'playing'

  // ── [Task 3 / Task 5] 게임 설정 ───────────────────────────────────────────
  /// 킬 쿨타임 (초). 서버 kill_cooldown 컬럼 → 기본 30초.
  final int killCooldown;
  /// 긴급 회의 쿨타임 (초). 서버 discussion_time 컬럼 → 기본 90초.
  final int emergencyCooldown;

  const Session({
    required this.id,
    required this.name,
    required this.code,
    required this.isHost,
    required this.memberCount,
    required this.members,
    required this.createdAt,
    this.expiresAt,
    this.activeModules = const [],
    this.moduleConfigs = const {},
    this.gameStatus = 'lobby',
    this.killCooldown = 30,
    this.emergencyCooldown = 90,
  });

  SessionType get sessionType => SessionType.fromModules(activeModules);

  factory Session.fromMap(Map<String, dynamic> m) {
    final rawMembers = m['members'] as List<dynamic>? ?? [];

    DateTime? parsedExpiresAt;
    if (m['expires_at'] != null) {
      parsedExpiresAt = DateTime.tryParse(m['expires_at'].toString());
    }

    final rawModules = m['active_modules'] as List<dynamic>? ?? [];
    final rawConfigs = m['module_configs'] as Map<String, dynamic>? ?? {};

    // kill_cooldown: 전용 컬럼 우선, module_configs 폴백
    final killCd = (m['kill_cooldown'] as num?)?.toInt()
        ?? (rawConfigs['killCooldown'] as num?)?.toInt()
        ?? 30;

    // discussion_time: 전용 컬럼 우선, module_configs 폴백 (emergencyCooldown 키)
    final emergencyCd = (m['discussion_time'] as num?)?.toInt()
        ?? (rawConfigs['emergencyCooldown'] as num?)?.toInt()
        ?? (rawConfigs['discussionTime'] as num?)?.toInt()
        ?? 90;

    return Session(
      id: m['id'] as String,
      name: m['name'] as String,
      code: (m['session_code'] ?? m['code']) as String? ?? '',
      isHost: m['is_host'] as bool? ?? false,
      memberCount:
          int.tryParse(m['member_count'].toString()) ?? rawMembers.length,
      members: rawMembers
          .whereType<Map<String, dynamic>>()
          .map(SessionMember.fromMap)
          .toList(),
      createdAt:
          DateTime.tryParse(m['created_at'] as String? ?? '') ?? DateTime.now(),
      expiresAt: parsedExpiresAt,
      activeModules: rawModules.whereType<String>().toList(),
      moduleConfigs: rawConfigs,
      gameStatus: m['game_status'] as String? ?? 'lobby',
      killCooldown: killCd,
      emergencyCooldown: emergencyCd,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 세션 타입 열거형
// ─────────────────────────────────────────────────────────────────────────────

enum SessionType {
  defaultType,
  chase,
  verbal,
  location;

  List<String> toModules() {
    switch (this) {
      case SessionType.defaultType:
        return [];
      case SessionType.chase:
        return ['proximity', 'tag', 'team'];
      case SessionType.verbal:
        return ['vote', 'round', 'team'];
      case SessionType.location:
        return ['mission', 'item'];
    }
  }

  static SessionType fromModules(List<String> modules) {
    if (modules.contains('proximity')) return SessionType.chase;
    if (modules.contains('vote')) return SessionType.verbal;
    if (modules.contains('mission')) return SessionType.location;
    return SessionType.defaultType;
  }

  int get minPlayers => this == SessionType.defaultType ? 2 : 2;
}

// ─────────────────────────────────────────────────────────────────────────────
// Repository
// ─────────────────────────────────────────────────────────────────────────────

class SessionRepository {
  final ApiClient _api = ApiClient();

  Future<List<Session>> getMySessions() async {
    final res = await _api.get('/sessions');
    final list = res.data['sessions'] as List<dynamic>? ?? [];
    return list.whereType<Map<String, dynamic>>().map(Session.fromMap).toList();
  }

  // ★ 수정됨: killCooldown / emergencyCooldown 파라미터 추가 [Task 5]
  Future<Session> createSession(
    String name,
    int durationHours,
    int maxMembers, {
    List<String> activeModules = const [],
    int killCooldown = 30,
    int emergencyCooldown = 90,
  }) async {
    final res = await _api.post(
      '/sessions',
      data: {
        'name': name,
        'durationHours': durationHours,
        'maxMembers': maxMembers,
        'activeModules': activeModules,
        'killCooldown': killCooldown,
        'discussionTime': emergencyCooldown,
      },
    );
    return Session.fromMap(res.data['session'] as Map<String, dynamic>);
  }

  Future<Session> joinSession(String code) async {
    final res = await _api.post('/sessions/join', data: {'code': code});
    return Session.fromMap(res.data['session'] as Map<String, dynamic>);
  }

  Future<Session> getSession(String id) async {
    try {
      final res = await _api.get('/sessions/$id');
      final data = res.data as Map<String, dynamic>?;
      final sessionMap =
          (data?['session'] as Map<String, dynamic>?) ?? data ?? {};
      return Session.fromMap(sessionMap);
    } catch (e) {
      debugPrint('[SessionRepository] getSession($id) error: $e');
      return Session(
        id: id,
        name: '',
        code: '',
        isHost: false,
        memberCount: 0,
        members: [],
        createdAt: DateTime.now(),
        expiresAt: null,
      );
    }
  }

  Future<void> leaveSession(String id) async {
    await _api.post('/sessions/$id/leave');
  }

  Future<void> endSession(String id) async {
    await _api.post('/sessions/$id/end');
  }

  Future<void> toggleSharing(String sessionId, bool enabled) async {
    await _api
        .patch('/sessions/$sessionId/sharing', data: {'enabled': enabled});
  }

  Future<void> updateMemberRole(
      String sessionId, String userId, String role) async {
    await _api.patch(
      '/sessions/$sessionId/members/$userId/role',
      data: {'role': role},
    );
  }

  Future<void> kickMember(String sessionId, String userId) async {
    await _api.delete('/sessions/$sessionId/members/$userId');
  }

  Future<void> startGame(String sessionId) async {
    await _api.post('/sessions/$sessionId/start');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Providers
// ─────────────────────────────────────────────────────────────────────────────

final sessionRepositoryProvider = Provider((ref) => SessionRepository());

// 내 세션 목록 상태 관리
class SessionListNotifier extends AsyncNotifier<List<Session>> {
  @override
  Future<List<Session>> build() => _fetch();

  Future<List<Session>> _fetch() =>
      ref.read(sessionRepositoryProvider).getMySessions();

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_fetch);
  }

  // 세션 생성 후 Session 객체를 반환 (lobby 이동에 사용) [Task 5: 게임 설정 추가]
  Future<Session> createSession(
    String name, {
    int durationHours = 1,
    int maxMembers = 3,
    List<String> activeModules = const [],
    int killCooldown = 30,
    int emergencyCooldown = 90,
  }) async {
    try {
      final session = await ref.read(sessionRepositoryProvider).createSession(
            name,
            durationHours,
            maxMembers,
            activeModules: activeModules,
            killCooldown: killCooldown,
            emergencyCooldown: emergencyCooldown,
          );

      // 세션 생성 후 목록 새로고침
      await refresh();

      return session;
    } catch (e) {
      rethrow;
    }
  }

  // 세션 참가 후 Session 객체를 반환 (lobby 이동에 사용)
  Future<Session> joinSession(String code) async {
    final session = await ref.read(sessionRepositoryProvider).joinSession(code);
    await refresh();
    return session;
  }

  Future<void> leaveSession(String sessionId) async {
    await ref.read(sessionRepositoryProvider).leaveSession(sessionId);
    await refresh();
  }
}

final sessionListProvider =
    AsyncNotifierProvider<SessionListNotifier, List<Session>>(
  SessionListNotifier.new,
);
