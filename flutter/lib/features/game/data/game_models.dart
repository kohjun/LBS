// lib/features/game/data/game_models.dart

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

  const GameMission({
    required this.id,
    required this.title,
    required this.zone,
    required this.type,
    required this.status,
    required this.isFake,
  });

  factory GameMission.fromMap(Map<String, dynamic> map) => GameMission(
        id:     map['missionId'] as String,
        title:  map['title']     as String? ?? '',
        zone:   map['zone']      as String? ?? '',
        type:   map['type']      as String? ?? 'mini_game',
        status: map['status']    as String? ?? 'pending',
        isFake: map['isFake']    as bool?   ?? false,
      );

  bool get isCompleted => status == 'completed';
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
  }) =>
      AmongUsGameState(
        isStarted:        isStarted        ?? this.isStarted,
        myRole:           myRole           ?? this.myRole,
        missions:         missions         ?? this.missions,
        missionProgress:  missionProgress  ?? this.missionProgress,
        chatLogs:         chatLogs         ?? this.chatLogs,
        meetingPhase:     meetingPhase     ?? this.meetingPhase,
        meetingRemaining: meetingRemaining ?? this.meetingRemaining,
        totalVoted:       totalVoted       ?? this.totalVoted,
        totalPlayers:     totalPlayers     ?? this.totalPlayers,
        voteResult:       voteResult       ?? this.voteResult,
        gameOverWinner:   gameOverWinner   ?? this.gameOverWinner,
        isAlive:          isAlive          ?? this.isAlive,
        preVoteCount:     preVoteCount     ?? this.preVoteCount,
        shouldNavigateToRole:
            shouldNavigateToRole ?? this.shouldNavigateToRole,
      );
}
