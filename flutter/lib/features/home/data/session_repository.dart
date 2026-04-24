// lib/features/home/data/session_repository.dart

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';
import '../../auth/data/auth_repository.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 데이터 모델
// ─────────────────────────────────────────────────────────────────────────────

class SessionMember {
  final String userId;
  final String nickname;
  final String? avatarUrl;
  final bool isHost;
  final String role; // 'host' | 'member'
  final String? teamId;
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
    this.teamId,
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
      teamId: m['team_id'] as String?,
      sharingEnabled: m['sharing_enabled'] as bool? ?? true,
      latitude: (loc?['lat'] as num?)?.toDouble(),
      longitude: (loc?['lng'] as num?)?.toDouble(),
      battery: loc?['battery'] as int?,
      status: loc?['status'] as String? ?? 'idle',
    );
  }
}

class FantasyWarsTeamConfig {
  final String teamId;
  final String displayName;
  final String color;

  const FantasyWarsTeamConfig({
    required this.teamId,
    required this.displayName,
    required this.color,
  });

  factory FantasyWarsTeamConfig.fromMap(Map<String, dynamic> map) {
    final teamId = map['teamId'] as String? ?? '';
    final defaults = _fantasyWarsTeamDefaults[teamId];
    return FantasyWarsTeamConfig(
      teamId: teamId,
      displayName: _normalizeFantasyWarsTeamDisplayName(
        map['displayName'] as String?,
        defaults?.displayName ?? '',
      ),
      color: map['color'] as String? ?? defaults?.color ?? '#9CA3AF',
    );
  }
}

const Map<String, FantasyWarsTeamConfig> _fantasyWarsTeamDefaults = {
  'guild_alpha': FantasyWarsTeamConfig(
    teamId: 'guild_alpha',
    displayName: '붉은 길드',
    color: '#DC2626',
  ),
  'guild_beta': FantasyWarsTeamConfig(
    teamId: 'guild_beta',
    displayName: '푸른 길드',
    color: '#2563EB',
  ),
  'guild_gamma': FantasyWarsTeamConfig(
    teamId: 'guild_gamma',
    displayName: '초록 길드',
    color: '#16A34A',
  ),
  'guild_delta': FantasyWarsTeamConfig(
    teamId: 'guild_delta',
    displayName: '황금 길드',
    color: '#D97706',
  ),
};

String _normalizeFantasyWarsTeamDisplayName(String? raw, String fallback) {
  final value = raw?.trim();
  if (value == null || value.isEmpty) {
    return fallback;
  }

  switch (value) {
    case 'Red Guild':
      return '붉은 길드';
    case 'Blue Guild':
      return '푸른 길드';
    case 'Green Guild':
      return '초록 길드';
    case 'Gold Guild':
      return '황금 길드';
    case 'Red Team':
      return '붉은 팀';
    case 'Blue Team':
      return '푸른 팀';
    case 'Green Team':
      return '초록 팀';
    default:
      return value;
  }
}

class FantasyWarsSpawnZone {
  final String teamId;
  final List<Map<String, double>> polygonPoints;

  const FantasyWarsSpawnZone({
    required this.teamId,
    required this.polygonPoints,
  });

  factory FantasyWarsSpawnZone.fromMap(Map<String, dynamic> map) {
    final rawPoints = map['polygonPoints'] as List<dynamic>? ?? const [];
    return FantasyWarsSpawnZone(
      teamId: map['teamId'] as String? ?? '',
      polygonPoints: rawPoints
          .whereType<Map<String, dynamic>>()
          .map((p) => {
                'lat': (p['lat'] as num).toDouble(),
                'lng': (p['lng'] as num).toDouble(),
              })
          .toList(),
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
  final DateTime? expiresAt;
  final List<String> activeModules;
  final Map<String, dynamic> moduleConfigs;
  final String gameStatus; // 'lobby' | 'playing'

  /// 플러그인 gameType ('among_us', 'fantasy_wars', …)
  final String gameType;
  /// 플러그인별 설정 맵
  final Map<String, dynamic> gameConfig;
  /// 플러그인 버전
  final String gameVersion;

  // ── 게임 설정 ────────────────────────────────────────────────────────────
  final int killCooldown;
  final int emergencyCooldown;
  final List<Map<String, double>>? playableArea;
  final List<FantasyWarsTeamConfig> fantasyWarsTeams;
  final List<Map<String, double>> fantasyWarsControlPoints;
  final List<FantasyWarsSpawnZone> fantasyWarsSpawnZones;

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
    this.gameType = 'among_us',
    this.gameConfig = const {},
    this.gameVersion = '1.0',
    this.killCooldown = 30,
    this.emergencyCooldown = 90,
    this.playableArea,
    this.fantasyWarsTeams = const [],
    this.fantasyWarsControlPoints = const [],
    this.fantasyWarsSpawnZones = const [],
  });

  /// AmongUs 내부 전용 — 외부에서 호출 금지
  SessionType get sessionType => SessionType.defaultType;

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

    // playable_area: [{lat, lng}, ...] 형태의 JSONB 배열 파싱
    final rawArea = m['playable_area'] as List<dynamic>?;
    final playableArea = rawArea
        ?.whereType<Map<String, dynamic>>()
        .map((p) => {
              'lat': (p['lat'] as num).toDouble(),
              'lng': (p['lng'] as num).toDouble(),
            })
        .toList();

    final rawGameType = m['game_type'] as String? ?? '';
    // 하위호환: game_type이 비어있으면 activeModules 기반 레거시 매핑
    final resolvedGameType = rawGameType.isEmpty ? 'among_us' : rawGameType;
    final gameConfig = (m['game_config'] as Map<String, dynamic>?) ?? {};
    final rawFantasyTeams = gameConfig['teams'] as List<dynamic>? ?? const [];
    final rawControlPoints =
        gameConfig['controlPoints'] as List<dynamic>? ?? const [];
    final rawSpawnZones = gameConfig['spawnZones'] as List<dynamic>? ?? const [];

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
      gameType: resolvedGameType,
      gameConfig: gameConfig,
      gameVersion: m['game_version'] as String? ?? '1.0',
      killCooldown: killCd,
      emergencyCooldown: emergencyCd,
      playableArea: playableArea,
      fantasyWarsTeams: rawFantasyTeams
          .whereType<Map<String, dynamic>>()
          .map(FantasyWarsTeamConfig.fromMap)
          .toList(),
      fantasyWarsControlPoints: rawControlPoints
          .whereType<Map<String, dynamic>>()
          .map((p) => {
                'lat': (p['lat'] as num).toDouble(),
                'lng': (p['lng'] as num).toDouble(),
              })
          .toList(),
      fantasyWarsSpawnZones: rawSpawnZones
          .whereType<Map<String, dynamic>>()
          .map(FantasyWarsSpawnZone.fromMap)
          .toList(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SessionType — AmongUs 레거시 전용. 신규 게임은 GameUiPluginRegistry를 사용.
// ─────────────────────────────────────────────────────────────────────────────

enum SessionType {
  defaultType,
  chase,
  verbal,
  location;

  /// AmongUs GameMainScreen 내부에서만 사용. 신규 코드에서 호출 금지.
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

  Future<Session> createSession(
    String name,
    int durationHours,
    int maxMembers, {
    String gameType = 'among_us',
    Map<String, dynamic> gameConfig = const {},
    String gameVersion = '1.0',
  }) async {
    final res = await _api.post(
      '/sessions',
      data: {
        'name': name,
        'durationHours': durationHours,
        'maxMembers': maxMembers,
        'gameType': gameType,
        'gameConfig': gameConfig,
        'gameVersion': gameVersion,
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

  /// 호스트가 플레이 가능 영역 폴리곤을 서버에 저장합니다.
  /// [points] 는 최소 3개의 좌표 목록 (lat, lng).
  Future<List<Map<String, double>>> setPlayableArea(
    String sessionId,
    List<Map<String, double>> points,
  ) async {
    final res = await _api.patch(
      '/sessions/$sessionId/playable-area',
      data: {
        'polygonPoints': points
            .map((p) => {'lat': p['lat'], 'lng': p['lng']})
            .toList(),
      },
    );
    final raw = res.data['playableArea'] as List<dynamic>? ?? [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map((p) => {
              'lat': (p['lat'] as num).toDouble(),
              'lng': (p['lng'] as num).toDouble(),
            })
        .toList();
  }

  Future<Session> setFantasyWarsLayout(
    String sessionId, {
    required List<Map<String, double>> playableArea,
    required List<Map<String, double>> controlPoints,
    required List<Map<String, dynamic>> spawnZones,
  }) async {
    await _api.patch(
      '/sessions/$sessionId/fantasy-wars-layout',
      data: {
        'playableArea': playableArea
            .map((p) => {'lat': p['lat'], 'lng': p['lng']})
            .toList(),
        'controlPoints': controlPoints
            .map((p) => {'lat': p['lat'], 'lng': p['lng']})
            .toList(),
        'spawnZones': spawnZones
            .map((zone) => {
                  'teamId': zone['teamId'],
                  'polygonPoints': ((zone['polygonPoints'] as List?) ?? const [])
                      .whereType<Map<String, double>>()
                      .map((p) => {'lat': p['lat'], 'lng': p['lng']})
                      .toList(),
                })
            .toList(),
      },
    );

    return getSession(sessionId);
  }

  Future<Session> updateFantasyWarsDuelConfig(
    String sessionId, {
    bool? allowGpsFallbackWithoutBle,
    int? bleEvidenceFreshnessMs,
  }) async {
    final data = <String, dynamic>{};
    if (allowGpsFallbackWithoutBle != null) {
      data['allowGpsFallbackWithoutBle'] = allowGpsFallbackWithoutBle;
    }
    if (bleEvidenceFreshnessMs != null) {
      data['bleEvidenceFreshnessMs'] = bleEvidenceFreshnessMs;
    }

    await _api.patch(
      '/sessions/$sessionId/fantasy-wars-duel-config',
      data: data,
    );

    return getSession(sessionId);
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

  Future<void> kickMember(String sessionId, String userId) async {
    await _api.delete('/sessions/$sessionId/members/$userId');
  }

  Future<void> moveMemberToTeam(
    String sessionId,
    String userId,
    String teamId,
  ) async {
    await _api.patch(
      '/sessions/$sessionId/members/$userId/team',
      data: {'teamId': teamId},
    );
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
  Future<List<Session>> build() async {
    // auth가 완전히 결정될 때까지 대기 (로딩 중 불필요한 401 방지)
    final user = await ref.watch(authProvider.future);
    if (user == null) return [];
    return _fetch();
  }

  Future<List<Session>> _fetch() =>
      ref.read(sessionRepositoryProvider).getMySessions();

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_fetch);
  }

  Future<Session> createSession(
    String name, {
    int durationHours = 1,
    int maxMembers = 3,
    String gameType = 'among_us',
    Map<String, dynamic> gameConfig = const {},
    String gameVersion = '1.0',
  }) async {
    try {
      final session = await ref.read(sessionRepositoryProvider).createSession(
            name,
            durationHours,
            maxMembers,
            gameType: gameType,
            gameConfig: gameConfig,
            gameVersion: gameVersion,
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
