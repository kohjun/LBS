// lib/features/game/data/game_models.dart

// ── 미니게임 미션 타입 / 상태 ──────────────────────────────────────────────────

enum MissionType { qr, location }

enum MissionStatus { locked, ready, completed }

class Mission {
  final String id;
  final String title;
  final String description;
  final MissionType type;
  final MissionStatus status;
  final double? targetLatitude;
  final double? targetLongitude;
  final double radius;
  final String minigameId;
  final bool isSabotaged;

  const Mission({
    required this.id,
    required this.title,
    required this.description,
    required this.type,
    required this.minigameId,
    this.status = MissionStatus.locked,
    this.targetLatitude,
    this.targetLongitude,
    this.radius = 15.0,
    this.isSabotaged = false,
  });

  Mission copyWith({
    String? id,
    String? title,
    String? description,
    MissionType? type,
    MissionStatus? status,
    double? targetLatitude,
    double? targetLongitude,
    double? radius,
    String? minigameId,
    bool? isSabotaged,
  }) =>
      Mission(
        id: id ?? this.id,
        title: title ?? this.title,
        description: description ?? this.description,
        type: type ?? this.type,
        status: status ?? this.status,
        targetLatitude: targetLatitude ?? this.targetLatitude,
        targetLongitude: targetLongitude ?? this.targetLongitude,
        radius: radius ?? this.radius,
        minigameId: minigameId ?? this.minigameId,
        isSabotaged: isSabotaged ?? this.isSabotaged,
      );
}

// ── 게임 역할 ──────────────────────────────────────────────────────────────────
class GameRole {
  final String role;        // 'crew' | 'impostor'
  final String team;
  final List<String> impostors; // 임포스터만 알 수 있음

  const GameRole({
    required this.role,
    required this.team,
    required this.impostors,
  });

  factory GameRole.fromMap(Map<String, dynamic> map) => GameRole(
        role:      map['role']      as String,
        team:      map['team']      as String,
        impostors: List<String>.from(map['impostors'] ?? []),
      );

  bool get isImpostor => role == 'impostor';
}

// ── 미션 ───────────────────────────────────────────────────────────────────────
class GameMission {
  final String id;
  final String title;
  final String zone;
  final String type;   // 'qr_scan' | 'mini_game' | 'stay'
  final String status; // 'pending' | 'in_progress' | 'completed'
  final bool isFake;
  /// 미션 수행 위치 (playable_area가 설정된 경우에만 존재)
  final double? lat;
  final double? lng;

  const GameMission({
    required this.id,
    required this.title,
    required this.zone,
    required this.type,
    required this.status,
    required this.isFake,
    this.lat,
    this.lng,
  });

  factory GameMission.fromMap(Map<String, dynamic> map) => GameMission(
        id:     map['missionId'] as String? ?? map['id'] as String,
        title:  map['title']     as String? ?? '',
        zone:   map['zone']      as String? ?? '',
        type:   map['type']      as String? ?? 'mini_game',
        status: map['status']    as String? ?? 'pending',
        isFake: map['isFake']    as bool?   ?? false,
        lat:    (map['lat']      as num?)?.toDouble(),
        lng:    (map['lng']      as num?)?.toDouble(),
      );

  bool get isCompleted => status == 'completed';
  bool get hasLocation => lat != null && lng != null;
}

// ── 투표 결과 ──────────────────────────────────────────────────────────────────
class VoteResult {
  final Map<String, int> voteCount;
  final String? ejectedId;
  final bool? wasImpostor;
  final bool isTied;
  final int totalVotes;

  const VoteResult({
    required this.voteCount,
    this.ejectedId,
    this.wasImpostor,
    required this.isTied,
    required this.totalVotes,
  });

  factory VoteResult.fromMap(Map<String, dynamic> map) => VoteResult(
        voteCount: Map<String, int>.from(
          (map['voteCount'] as Map?)
                  ?.map((k, v) => MapEntry(k as String, v as int)) ??
              {},
        ),
        ejectedId:   (map['ejected']  as Map?)?['userId'] as String?,
        wasImpostor: map['wasImpostor'] as bool?,
        isTied:      map['isTied']      as bool? ?? false,
        totalVotes:  map['totalVotes']  as int?  ?? 0,
      );
}

// ── AI 채팅 로그 ───────────────────────────────────────────────────────────────
enum ChatLogType { aiAnnounce, aiReply, myQuestion, system }

class ChatLog {
  final String id;
  final ChatLogType type;
  final String message;
  final DateTime timestamp;

  const ChatLog({
    required this.id,
    required this.type,
    required this.message,
    required this.timestamp,
  });
}

// ── 게임 전체 상태 ─────────────────────────────────────────────────────────────
class AmongUsGameState {
  final bool isStarted;
  final GameRole? myRole;
  final List<GameMission> missions;
  final Map<String, dynamic> missionProgress;
  final List<ChatLog> chatLogs;
  final String meetingPhase; // 'none' | 'discussion' | 'voting' | 'result'
  final int meetingRemaining;
  final int totalVoted;
  final int totalPlayers;
  final VoteResult? voteResult;
  final String? gameOverWinner; // 'crew' | 'impostor'
  final bool isAlive;
  final int preVoteCount;
  final bool shouldNavigateToRole;
  /// 호스트가 설정한 플레이 가능 영역 폴리곤 좌표 목록.
  /// 설정된 경우 이탈 경고 및 미션 활성화 판정에 사용됩니다.
  final List<Map<String, double>>? playableArea;
  /// 현재 플레이어의 위치가 활성화 반경(15m) 이내에 있는 미션 ID 목록.
  /// 이 목록에 포함된 미션만 '수행하기' 버튼이 활성화됩니다.
  final List<String> nearbyMissionIds;

  /// 지오펜스·QR 기반 미니게임 미션 목록.
  final List<Mission> myMissions;

  /// 전체 태스크 진행도 (0.0 ~ 1.0). 서버 task_progress 이벤트로 갱신됩니다.
  final double totalTaskProgress;

  /// 회의 시작 이벤트를 수신했을 때 true → 상위 위젯이 GameMeetingScreen으로 이동 후 false로 리셋.
  final bool shouldNavigateToMeeting;

  /// 회의 쿨타임 중 여부 (버튼 비활성화 표시용).
  final bool isMeetingCoolingDown;

  const AmongUsGameState({
    this.isStarted        = false,
    this.myRole,
    this.missions         = const [],
    this.missionProgress  = const {
      'completed': 0,
      'total': 0,
      'percent': 0,
    },
    this.chatLogs         = const [],
    this.meetingPhase     = 'none',
    this.meetingRemaining = 0,
    this.totalVoted       = 0,
    this.totalPlayers     = 0,
    this.voteResult,
    this.gameOverWinner,
    this.isAlive          = true,
    this.preVoteCount     = 0,
    this.shouldNavigateToRole = false,
    this.playableArea,
    this.nearbyMissionIds = const [],
    this.myMissions = const [],
    this.totalTaskProgress = 0.0,
    this.shouldNavigateToMeeting = false,
    this.isMeetingCoolingDown = false,
  });

  AmongUsGameState copyWith({
    bool? isStarted,
    GameRole? myRole,
    List<GameMission>? missions,
    Map<String, dynamic>? missionProgress,
    List<ChatLog>? chatLogs,
    String? meetingPhase,
    int? meetingRemaining,
    int? totalVoted,
    int? totalPlayers,
    VoteResult? voteResult,
    String? gameOverWinner,
    bool? isAlive,
    int? preVoteCount,
    bool? shouldNavigateToRole,
    List<Map<String, double>>? playableArea,
    List<String>? nearbyMissionIds,
    List<Mission>? myMissions,
    double? totalTaskProgress,
    bool? shouldNavigateToMeeting,
    bool? isMeetingCoolingDown,
  }) =>
      AmongUsGameState(
        isStarted:              isStarted              ?? this.isStarted,
        myRole:                 myRole                 ?? this.myRole,
        missions:               missions               ?? this.missions,
        missionProgress:        missionProgress        ?? this.missionProgress,
        chatLogs:               chatLogs               ?? this.chatLogs,
        meetingPhase:           meetingPhase           ?? this.meetingPhase,
        meetingRemaining:       meetingRemaining       ?? this.meetingRemaining,
        totalVoted:             totalVoted             ?? this.totalVoted,
        totalPlayers:           totalPlayers           ?? this.totalPlayers,
        voteResult:             voteResult             ?? this.voteResult,
        gameOverWinner:         gameOverWinner         ?? this.gameOverWinner,
        isAlive:                isAlive                ?? this.isAlive,
        preVoteCount:           preVoteCount           ?? this.preVoteCount,
        shouldNavigateToRole:
            shouldNavigateToRole ?? this.shouldNavigateToRole,
        playableArea:           playableArea           ?? this.playableArea,
        nearbyMissionIds:       nearbyMissionIds       ?? this.nearbyMissionIds,
        myMissions:             myMissions             ?? this.myMissions,
        totalTaskProgress:      totalTaskProgress      ?? this.totalTaskProgress,
        shouldNavigateToMeeting:
            shouldNavigateToMeeting ?? this.shouldNavigateToMeeting,
        isMeetingCoolingDown:
            isMeetingCoolingDown ?? this.isMeetingCoolingDown,
      );
}

