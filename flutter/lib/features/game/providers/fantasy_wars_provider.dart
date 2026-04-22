import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/socket_service.dart';
import '../../auth/data/auth_repository.dart';

const Object _fwSentinel = Object();

@immutable
class FwGeoPoint {
  const FwGeoPoint({
    required this.lat,
    required this.lng,
  });

  final double lat;
  final double lng;

  factory FwGeoPoint.fromMap(Map<String, dynamic> map) => FwGeoPoint(
        lat: (map['lat'] as num?)?.toDouble() ?? 0,
        lng: (map['lng'] as num?)?.toDouble() ?? 0,
      );
}

@immutable
class FwSpawnZone {
  const FwSpawnZone({
    required this.teamId,
    required this.polygonPoints,
    this.displayName,
    this.colorHex,
  });

  final String teamId;
  final String? displayName;
  final String? colorHex;
  final List<FwGeoPoint> polygonPoints;

  factory FwSpawnZone.fromMap(Map<String, dynamic> map) => FwSpawnZone(
        teamId: map['teamId'] as String? ?? '',
        displayName: map['displayName'] as String?,
        colorHex: map['color'] as String?,
        polygonPoints: ((map['polygonPoints'] as List?) ?? const [])
            .whereType<Map>()
            .map(
                (value) => FwGeoPoint.fromMap(Map<String, dynamic>.from(value)))
            .toList(),
      );
}

@immutable
class FwDuelResult {
  const FwDuelResult({
    required this.winnerId,
    required this.loserId,
    required this.reason,
    this.shieldAbsorbed = false,
    this.executionTriggered = false,
    this.warriorHpResult,
  });

  final String? winnerId;
  final String? loserId;
  final String reason;
  final bool shieldAbsorbed;
  final bool executionTriggered;
  final int? warriorHpResult;

  bool get isDraw => winnerId == null || winnerId!.isEmpty;

  factory FwDuelResult.fromMap(Map<String, dynamic> map) {
    final verdict = (map['verdict'] as Map?)?.cast<String, dynamic>() ?? map;
    final effects =
        (verdict['effects'] as Map?)?.cast<String, dynamic>() ?? const {};
    final winner = verdict['winner'] as String?;
    final loser = verdict['loser'] as String?;

    return FwDuelResult(
      winnerId: (winner == null || winner.isEmpty) ? null : winner,
      loserId: (loser == null || loser.isEmpty) ? null : loser,
      reason: verdict['reason'] as String? ?? 'minigame',
      shieldAbsorbed: effects['shieldAbsorbed'] as bool? ?? false,
      executionTriggered: effects['executionTriggered'] as bool? ?? false,
      warriorHpResult: (effects['warriorHp'] as num?)?.toInt(),
    );
  }

  static FwDuelResult invalidated() => const FwDuelResult(
        winnerId: null,
        loserId: null,
        reason: 'invalidated',
      );
}

@immutable
class FwArtifactState {
  const FwArtifactState({
    required this.id,
    this.heldBy,
  });

  final String id;
  final String? heldBy;

  factory FwArtifactState.fromMap(Map<String, dynamic> map) => FwArtifactState(
        id: map['id'] as String? ?? 'artifact_main',
        heldBy: map['heldBy'] as String?,
      );
}

@immutable
class FwDungeonState {
  const FwDungeonState({
    required this.id,
    required this.displayName,
    this.status = 'open',
    this.artifact = const FwArtifactState(id: 'artifact_main'),
  });

  final String id;
  final String displayName;
  final String status;
  final FwArtifactState artifact;

  factory FwDungeonState.fromMap(Map<String, dynamic> map) => FwDungeonState(
        id: map['id'] as String? ?? 'dungeon_main',
        displayName:
            map['displayName'] as String? ?? map['id'] as String? ?? 'Dungeon',
        status: map['status'] as String? ?? 'open',
        artifact: FwArtifactState.fromMap(
          (map['artifact'] as Map?)?.cast<String, dynamic>() ?? const {},
        ),
      );
}

@immutable
class FwControlPoint {
  const FwControlPoint({
    required this.id,
    required this.displayName,
    this.capturedBy,
    this.capturingGuild,
    this.captureProgress = 0,
    this.captureStartedAt,
    this.readyCount = 0,
    this.requiredCount = 0,
    this.blockadedBy,
    this.blockadeExpiresAt,
    this.lat,
    this.lng,
  });

  final String id;
  final String displayName;
  final String? capturedBy;
  final String? capturingGuild;
  final int captureProgress;
  final int? captureStartedAt;
  final int readyCount;
  final int requiredCount;
  final String? blockadedBy;
  final int? blockadeExpiresAt;
  final double? lat;
  final double? lng;

  bool get isBlockaded {
    if (blockadedBy == null) {
      return false;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    return blockadeExpiresAt == null || blockadeExpiresAt! > now;
  }

  bool get isPreparing => readyCount > 0 && capturingGuild != null;

  factory FwControlPoint.fromMap(Map<String, dynamic> map) {
    final location =
        (map['location'] as Map?)?.cast<String, dynamic>() ?? const {};
    return FwControlPoint(
      id: map['id'] as String,
      displayName: map['displayName'] as String? ?? map['id'] as String,
      capturedBy: map['capturedBy'] as String?,
      capturingGuild: map['capturingGuild'] as String?,
      captureProgress: (map['captureProgress'] as num?)?.toInt() ?? 0,
      captureStartedAt: (map['captureStartedAt'] as num?)?.toInt(),
      readyCount: (map['readyCount'] as num?)?.toInt() ?? 0,
      requiredCount: (map['requiredCount'] as num?)?.toInt() ?? 0,
      blockadedBy: map['blockadedBy'] as String?,
      blockadeExpiresAt: (map['blockadeExpiresAt'] as num?)?.toInt(),
      lat: (location['lat'] as num?)?.toDouble(),
      lng: (location['lng'] as num?)?.toDouble(),
    );
  }

  FwControlPoint copyWith({
    Object? capturedBy = _fwSentinel,
    Object? capturingGuild = _fwSentinel,
    int? captureProgress,
    Object? captureStartedAt = _fwSentinel,
    int? readyCount,
    int? requiredCount,
    Object? blockadedBy = _fwSentinel,
    Object? blockadeExpiresAt = _fwSentinel,
  }) {
    return FwControlPoint(
      id: id,
      displayName: displayName,
      capturedBy:
          capturedBy == _fwSentinel ? this.capturedBy : capturedBy as String?,
      capturingGuild: capturingGuild == _fwSentinel
          ? this.capturingGuild
          : capturingGuild as String?,
      captureProgress: captureProgress ?? this.captureProgress,
      captureStartedAt: captureStartedAt == _fwSentinel
          ? this.captureStartedAt
          : captureStartedAt as int?,
      readyCount: readyCount ?? this.readyCount,
      requiredCount: requiredCount ?? this.requiredCount,
      blockadedBy: blockadedBy == _fwSentinel
          ? this.blockadedBy
          : blockadedBy as String?,
      blockadeExpiresAt: blockadeExpiresAt == _fwSentinel
          ? this.blockadeExpiresAt
          : blockadeExpiresAt as int?,
      lat: lat,
      lng: lng,
    );
  }
}

@immutable
class FwGuildInfo {
  const FwGuildInfo({
    required this.guildId,
    required this.displayName,
    this.score = 0,
    this.memberIds = const [],
    this.guildMasterId,
  });

  final String guildId;
  final String displayName;
  final int score;
  final List<String> memberIds;
  final String? guildMasterId;

  factory FwGuildInfo.fromMap(Map<String, dynamic> map) => FwGuildInfo(
        guildId: map['guildId'] as String,
        displayName: map['displayName'] as String? ?? map['guildId'] as String,
        score: (map['score'] as num?)?.toInt() ?? 0,
        memberIds: (map['memberIds'] as List?)?.whereType<String>().toList() ??
            const [],
        guildMasterId: map['guildMasterId'] as String?,
      );
}

@immutable
class FwMyState {
  const FwMyState({
    this.guildId,
    this.job,
    this.isGuildMaster = false,
    this.isAlive = true,
    this.hp = 100,
    this.remainingLives = 1,
    this.shieldCount = 0,
    this.captureZone,
    this.inDuel = false,
    this.duelExpiresAt,
    this.executionArmedUntil,
    this.buffedUntil,
    this.revealUntil,
    this.trackedTargetUserId,
    this.dungeonEntered = false,
    this.nextReviveChance,
    this.skillUsedAt = const {},
  });

  final String? guildId;
  final String? job;
  final bool isGuildMaster;
  final bool isAlive;
  final int hp;
  final int remainingLives;
  final int shieldCount;
  final String? captureZone;
  final bool inDuel;
  final int? duelExpiresAt;
  final int? executionArmedUntil;
  final int? buffedUntil;
  final int? revealUntil;
  final String? trackedTargetUserId;
  final bool dungeonEntered;
  final double? nextReviveChance;
  final Map<String, int> skillUsedAt;

  bool get isExecutionReady =>
      executionArmedUntil != null &&
      executionArmedUntil! > DateTime.now().millisecondsSinceEpoch;

  bool get isRevealActive =>
      revealUntil != null &&
      revealUntil! > DateTime.now().millisecondsSinceEpoch;

  bool get isBuffActive =>
      buffedUntil != null &&
      buffedUntil! > DateTime.now().millisecondsSinceEpoch;

  FwMyState copyWith({
    Object? guildId = _fwSentinel,
    Object? job = _fwSentinel,
    bool? isGuildMaster,
    bool? isAlive,
    int? hp,
    int? remainingLives,
    int? shieldCount,
    Object? captureZone = _fwSentinel,
    bool? inDuel,
    Object? duelExpiresAt = _fwSentinel,
    Object? executionArmedUntil = _fwSentinel,
    Object? buffedUntil = _fwSentinel,
    Object? revealUntil = _fwSentinel,
    Object? trackedTargetUserId = _fwSentinel,
    bool? dungeonEntered,
    Object? nextReviveChance = _fwSentinel,
    Map<String, int>? skillUsedAt,
  }) {
    return FwMyState(
      guildId: guildId == _fwSentinel ? this.guildId : guildId as String?,
      job: job == _fwSentinel ? this.job : job as String?,
      isGuildMaster: isGuildMaster ?? this.isGuildMaster,
      isAlive: isAlive ?? this.isAlive,
      hp: hp ?? this.hp,
      remainingLives: remainingLives ?? this.remainingLives,
      shieldCount: shieldCount ?? this.shieldCount,
      captureZone: captureZone == _fwSentinel
          ? this.captureZone
          : captureZone as String?,
      inDuel: inDuel ?? this.inDuel,
      duelExpiresAt: duelExpiresAt == _fwSentinel
          ? this.duelExpiresAt
          : duelExpiresAt as int?,
      executionArmedUntil: executionArmedUntil == _fwSentinel
          ? this.executionArmedUntil
          : executionArmedUntil as int?,
      buffedUntil:
          buffedUntil == _fwSentinel ? this.buffedUntil : buffedUntil as int?,
      revealUntil:
          revealUntil == _fwSentinel ? this.revealUntil : revealUntil as int?,
      trackedTargetUserId: trackedTargetUserId == _fwSentinel
          ? this.trackedTargetUserId
          : trackedTargetUserId as String?,
      dungeonEntered: dungeonEntered ?? this.dungeonEntered,
      nextReviveChance: nextReviveChance == _fwSentinel
          ? this.nextReviveChance
          : nextReviveChance as double?,
      skillUsedAt: skillUsedAt ?? this.skillUsedAt,
    );
  }
}

@immutable
class FwDuelState {
  const FwDuelState({
    this.duelId,
    this.opponentId,
    this.phase = 'idle',
    this.minigameType,
    this.minigameParams,
    this.duelResult,
    this.submitted = false,
  });

  final String? duelId;
  final String? opponentId;
  final String phase;
  final String? minigameType;
  final Map<String, dynamic>? minigameParams;
  final FwDuelResult? duelResult;
  final bool submitted;

  FwDuelState copyWith({
    Object? duelId = _fwSentinel,
    Object? opponentId = _fwSentinel,
    String? phase,
    Object? minigameType = _fwSentinel,
    Object? minigameParams = _fwSentinel,
    Object? duelResult = _fwSentinel,
    bool? submitted,
  }) {
    return FwDuelState(
      duelId: duelId == _fwSentinel ? this.duelId : duelId as String?,
      opponentId:
          opponentId == _fwSentinel ? this.opponentId : opponentId as String?,
      phase: phase ?? this.phase,
      minigameType: minigameType == _fwSentinel
          ? this.minigameType
          : minigameType as String?,
      minigameParams: minigameParams == _fwSentinel
          ? this.minigameParams
          : minigameParams as Map<String, dynamic>?,
      duelResult: duelResult == _fwSentinel
          ? this.duelResult
          : duelResult as FwDuelResult?,
      submitted: submitted ?? this.submitted,
    );
  }
}

@immutable
class FantasyWarsGameState {
  const FantasyWarsGameState({
    this.status = 'none',
    this.guilds = const {},
    this.controlPoints = const [],
    this.playableArea = const [],
    this.spawnZones = const [],
    this.dungeons = const [],
    this.alivePlayerIds = const [],
    this.eliminatedPlayerIds = const [],
    this.winCondition,
    this.myState = const FwMyState(),
    this.duel = const FwDuelState(),
  });

  final String status;
  final Map<String, FwGuildInfo> guilds;
  final List<FwControlPoint> controlPoints;
  final List<FwGeoPoint> playableArea;
  final List<FwSpawnZone> spawnZones;
  final List<FwDungeonState> dungeons;
  final List<String> alivePlayerIds;
  final List<String> eliminatedPlayerIds;
  final Map<String, dynamic>? winCondition;
  final FwMyState myState;
  final FwDuelState duel;

  bool get isStarted => status == 'in_progress';
  bool get isFinished => status == 'finished';

  FantasyWarsGameState copyWith({
    String? status,
    Map<String, FwGuildInfo>? guilds,
    List<FwControlPoint>? controlPoints,
    List<FwGeoPoint>? playableArea,
    List<FwSpawnZone>? spawnZones,
    List<FwDungeonState>? dungeons,
    List<String>? alivePlayerIds,
    List<String>? eliminatedPlayerIds,
    Object? winCondition = _fwSentinel,
    FwMyState? myState,
    FwDuelState? duel,
  }) {
    return FantasyWarsGameState(
      status: status ?? this.status,
      guilds: guilds ?? this.guilds,
      controlPoints: controlPoints ?? this.controlPoints,
      playableArea: playableArea ?? this.playableArea,
      spawnZones: spawnZones ?? this.spawnZones,
      dungeons: dungeons ?? this.dungeons,
      alivePlayerIds: alivePlayerIds ?? this.alivePlayerIds,
      eliminatedPlayerIds: eliminatedPlayerIds ?? this.eliminatedPlayerIds,
      winCondition: winCondition == _fwSentinel
          ? this.winCondition
          : winCondition as Map<String, dynamic>?,
      myState: myState ?? this.myState,
      duel: duel ?? this.duel,
    );
  }
}

abstract class FantasyWarsSocketClient {
  bool get isConnected;
  Stream<bool> get onConnectionChange;
  Stream<Map<String, dynamic>> get onGameStateUpdate;
  Stream<Map<String, dynamic>> onGameEvent(String event);
  Stream<Map<String, dynamic>> get onFwDuelChallenged;
  Stream<Map<String, dynamic>> get onFwDuelAccepted;
  Stream<Map<String, dynamic>> get onFwDuelRejected;
  Stream<Map<String, dynamic>> get onFwDuelCancelled;
  Stream<Map<String, dynamic>> get onFwDuelStarted;
  Stream<Map<String, dynamic>> get onFwDuelResult;
  Stream<Map<String, dynamic>> get onFwDuelInvalidated;
  void requestGameState(String sessionId);
  Future<Map<String, dynamic>> sendFwCaptureStart(
      String sessionId, String controlPointId);
  Future<Map<String, dynamic>> sendFwCaptureCancel(
      String sessionId, String controlPointId);
  Future<Map<String, dynamic>> sendFwDungeonEnter(
    String sessionId, {
    String dungeonId = 'dungeon_main',
  });
  Future<Map<String, dynamic>> sendFwUseSkill(
    String sessionId, {
    required String skill,
    String? targetUserId,
    String? controlPointId,
  });
  Future<Map<String, dynamic>> sendDuelChallenge(
      String sessionId, String targetUserId);
  Future<Map<String, dynamic>> sendDuelAccept(String duelId);
  Future<Map<String, dynamic>> sendDuelReject(String duelId);
  Future<Map<String, dynamic>> sendDuelCancel(String duelId);
  Future<Map<String, dynamic>> sendDuelSubmit(
      String duelId, Map<String, dynamic> result);
}

class SocketServiceFantasyWarsClient implements FantasyWarsSocketClient {
  SocketServiceFantasyWarsClient(this._socket);

  final SocketService _socket;

  @override
  bool get isConnected => _socket.isConnected;

  @override
  Stream<bool> get onConnectionChange => _socket.onConnectionChange;

  @override
  Stream<Map<String, dynamic>> get onGameStateUpdate =>
      _socket.onGameStateUpdate;

  @override
  Stream<Map<String, dynamic>> onGameEvent(String event) =>
      _socket.onGameEvent(event);

  @override
  Stream<Map<String, dynamic>> get onFwDuelChallenged =>
      _socket.onFwDuelChallenged;

  @override
  Stream<Map<String, dynamic>> get onFwDuelAccepted => _socket.onFwDuelAccepted;

  @override
  Stream<Map<String, dynamic>> get onFwDuelRejected => _socket.onFwDuelRejected;

  @override
  Stream<Map<String, dynamic>> get onFwDuelCancelled =>
      _socket.onFwDuelCancelled;

  @override
  Stream<Map<String, dynamic>> get onFwDuelStarted => _socket.onFwDuelStarted;

  @override
  Stream<Map<String, dynamic>> get onFwDuelResult => _socket.onFwDuelResult;

  @override
  Stream<Map<String, dynamic>> get onFwDuelInvalidated =>
      _socket.onFwDuelInvalidated;

  @override
  void requestGameState(String sessionId) =>
      _socket.requestGameState(sessionId);

  @override
  Future<Map<String, dynamic>> sendFwCaptureStart(
          String sessionId, String controlPointId) =>
      _socket.sendFwCaptureStart(sessionId, controlPointId);

  @override
  Future<Map<String, dynamic>> sendFwCaptureCancel(
          String sessionId, String controlPointId) =>
      _socket.sendFwCaptureCancel(sessionId, controlPointId);

  @override
  Future<Map<String, dynamic>> sendFwDungeonEnter(
    String sessionId, {
    String dungeonId = 'dungeon_main',
  }) =>
      _socket.sendFwDungeonEnter(sessionId, dungeonId: dungeonId);

  @override
  Future<Map<String, dynamic>> sendFwUseSkill(
    String sessionId, {
    required String skill,
    String? targetUserId,
    String? controlPointId,
  }) =>
      _socket.sendFwUseSkill(
        sessionId,
        skill: skill,
        targetUserId: targetUserId,
        controlPointId: controlPointId,
      );

  @override
  Future<Map<String, dynamic>> sendDuelChallenge(
          String sessionId, String targetUserId) =>
      _socket.sendDuelChallenge(sessionId, targetUserId);

  @override
  Future<Map<String, dynamic>> sendDuelAccept(String duelId) =>
      _socket.sendDuelAccept(duelId);

  @override
  Future<Map<String, dynamic>> sendDuelReject(String duelId) =>
      _socket.sendDuelReject(duelId);

  @override
  Future<Map<String, dynamic>> sendDuelCancel(String duelId) =>
      _socket.sendDuelCancel(duelId);

  @override
  Future<Map<String, dynamic>> sendDuelSubmit(
          String duelId, Map<String, dynamic> result) =>
      _socket.sendDuelSubmit(duelId, result);
}

final fantasyWarsSocketClientProvider = Provider<FantasyWarsSocketClient>(
  (ref) => SocketServiceFantasyWarsClient(SocketService()),
);

final fantasyWarsCurrentUserIdProvider = Provider<String?>(
  (ref) => ref.watch(authProvider).valueOrNull?.id,
);

final fantasyWarsProvider = StateNotifierProvider.family<FantasyWarsNotifier,
    FantasyWarsGameState, String>(
  (ref, sessionId) => FantasyWarsNotifier(
    sessionId: sessionId,
    socket: ref.read(fantasyWarsSocketClientProvider),
    getCurrentUserId: () => ref.read(fantasyWarsCurrentUserIdProvider),
  ),
);

class FantasyWarsNotifier extends StateNotifier<FantasyWarsGameState> {
  FantasyWarsNotifier({
    required String sessionId,
    required FantasyWarsSocketClient socket,
    required String? Function() getCurrentUserId,
  })  : _sessionId = sessionId,
        _socket = socket,
        _getCurrentUserId = getCurrentUserId,
        super(const FantasyWarsGameState()) {
    _subscribeAll();
    if (_socket.isConnected) {
      _requestStateNow();
    }
  }

  final String _sessionId;
  final FantasyWarsSocketClient _socket;
  final String? Function() _getCurrentUserId;
  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _duelResultClearTimer;
  Timer? _stateRefreshTimer;

  String? get _myUserId => _getCurrentUserId();

  void _subscribeAll() {
    _subs.add(_socket.onConnectionChange.listen((connected) {
      if (connected) {
        _requestStateNow();
      }
    }));

    _subs.add(_socket.onGameStateUpdate.listen(_handleStateUpdate));

    _subs.add(_socket.onGameEvent(SocketService.gameStarted).listen((data) {
      _handleStateUpdate({...data, 'status': 'in_progress'});
    }));

    _subs.add(_socket.onGameEvent(SocketService.gameOver).listen((data) {
      state = state.copyWith(
        status: 'finished',
        winCondition: Map<String, dynamic>.from(data),
      );
    }));

    _subs.add(_socket.onGameEvent('fw:capture_progress').listen((data) {
      _mutateControlPoint(data['controlPointId'] as String?, (cp) {
        return cp.copyWith(
          capturingGuild: data['guildId'] as String?,
          readyCount: (data['readyCount'] as num?)?.toInt() ?? cp.readyCount,
          requiredCount:
              (data['requiredCount'] as num?)?.toInt() ?? cp.requiredCount,
        );
      });
    }));

    _subs.add(_socket.onGameEvent('fw:capture_started').listen((data) {
      _mutateControlPoint(data['controlPointId'] as String?, (cp) {
        return cp.copyWith(
          capturingGuild: data['guildId'] as String?,
          captureStartedAt: (data['startedAt'] as num?)?.toInt(),
          captureProgress: 0,
          readyCount: 0,
          requiredCount: 0,
        );
      });
      if (data['guildId'] == state.myState.guildId) {
        _scheduleStateRefresh();
      }
    }));

    _subs.add(_socket.onGameEvent('fw:capture_complete').listen((data) {
      _mutateControlPoint(data['controlPointId'] as String?, (cp) {
        return cp.copyWith(
          capturedBy: data['capturedBy'] as String?,
          capturingGuild: null,
          captureStartedAt: null,
          captureProgress: 100,
          readyCount: 0,
          requiredCount: 0,
        );
      });
      _scheduleStateRefresh();
    }));

    _subs.add(_socket.onGameEvent('fw:capture_cancelled').listen((data) {
      _mutateControlPoint(data['controlPointId'] as String?, (cp) {
        return cp.copyWith(
          capturingGuild: null,
          captureStartedAt: null,
          captureProgress: 0,
          readyCount: 0,
          requiredCount: 0,
        );
      });
      if (data['guildId'] == state.myState.guildId ||
          data['interruptedByGuild'] == state.myState.guildId) {
        _scheduleStateRefresh();
      }
    }));

    _subs.add(_socket.onGameEvent('fw:player_attacked').listen((data) {
      final myUserId = _myUserId;
      if (myUserId == null) {
        return;
      }
      if (data['targetId'] == myUserId) {
        state = state.copyWith(
          myState: state.myState.copyWith(
            hp: (data['targetHp'] as num?)?.toInt() ?? state.myState.hp,
          ),
        );
      }
    }));

    _subs.add(_socket.onGameEvent('fw:player_eliminated').listen((data) {
      final eliminatedId = data['userId'] as String?;
      if (eliminatedId == null) {
        return;
      }

      final alive =
          state.alivePlayerIds.where((id) => id != eliminatedId).toList();
      final eliminated =
          <String>{...state.eliminatedPlayerIds, eliminatedId}.toList();
      state = state.copyWith(
        alivePlayerIds: alive,
        eliminatedPlayerIds: eliminated,
      );

      if (eliminatedId == _myUserId) {
        state = state.copyWith(
          myState: state.myState.copyWith(
            isAlive: false,
            hp: 0,
            inDuel: false,
            dungeonEntered: false,
            captureZone: null,
          ),
        );
        _scheduleStateRefresh();
      }
    }));

    _subs.add(_socket.onGameEvent('fw:player_revived').listen((data) {
      final revivedId = data['targetUserId'] as String?;
      if (revivedId == null) {
        return;
      }

      final eliminated =
          state.eliminatedPlayerIds.where((id) => id != revivedId).toList();
      final alive = <String>{...state.alivePlayerIds, revivedId}.toList();
      state = state.copyWith(
        alivePlayerIds: alive,
        eliminatedPlayerIds: eliminated,
      );

      if (revivedId == _myUserId) {
        state = state.copyWith(
          myState: state.myState.copyWith(
            isAlive: true,
            hp: 100,
            remainingLives: state.myState.job == 'warrior' ? 2 : 1,
            dungeonEntered: false,
            nextReviveChance: null,
          ),
        );
        _scheduleStateRefresh();
      }
    }));

    _subs.add(_socket.onGameEvent('fw:revive_failed').listen((data) {
      final targetUserId = data['targetUserId'] as String?;
      if (targetUserId == null || targetUserId != _myUserId) {
        return;
      }

      state = state.copyWith(
        myState: state.myState.copyWith(
          dungeonEntered: true,
          nextReviveChance: (data['nextChance'] as num?)?.toDouble(),
        ),
      );
    }));

    _subs.add(_socket.onGameEvent('fw:skill_cooldown').listen((data) {
      final skill = data['skill'] as String?;
      final remainSec = (data['remainSec'] as num?)?.toInt() ?? 0;
      if (skill == null) {
        return;
      }

      final updated = Map<String, int>.from(state.myState.skillUsedAt)
        ..[skill] = DateTime.now().millisecondsSinceEpoch + remainSec * 1000;

      state = state.copyWith(
        myState: state.myState.copyWith(skillUsedAt: updated),
      );
    }));

    _subs.add(_socket.onGameEvent('fw:skill_used').listen((data) {
      final skill = data['skill'] as String?;
      if (skill == null) {
        return;
      }
      final cooldownMs = _cooldownMsForSkill(skill);
      if (cooldownMs <= 0) {
        return;
      }

      final updated = Map<String, int>.from(state.myState.skillUsedAt)
        ..[skill] = DateTime.now().millisecondsSinceEpoch + cooldownMs;
      state = state.copyWith(
        myState: state.myState.copyWith(skillUsedAt: updated),
      );
    }));

    _subs.add(_socket.onGameEvent('fw:player_skill').listen((data) {
      final actorId = data['userId'] as String?;
      final result =
          (data['result'] as Map?)?.cast<String, dynamic>() ?? const {};
      final type = result['type'] as String?;
      if (type == null) {
        return;
      }

      switch (type) {
        case 'blockade':
          final cpId = result['cpId'] as String?;
          final actorGuildId =
              actorId == null ? null : _guildIdForUser(actorId);
          _mutateControlPoint(cpId, (cp) {
            return cp.copyWith(
              blockadedBy: actorGuildId,
              blockadeExpiresAt: (result['expiresAt'] as num?)?.toInt(),
            );
          });
          break;
        case 'shield':
          final targetUserId = result['targetUserId'] as String?;
          if (targetUserId == _myUserId) {
            state = state.copyWith(
              myState: state.myState.copyWith(
                shieldCount: (result['shieldCount'] as num?)?.toInt() ??
                    state.myState.shieldCount + 1,
              ),
            );
            _scheduleStateRefresh();
          }
          break;
        case 'reveal':
          if (actorId == _myUserId) {
            state = state.copyWith(
              myState: state.myState.copyWith(
                revealUntil: (result['revealUntil'] as num?)?.toInt(),
                trackedTargetUserId: result['targetUserId'] as String?,
              ),
            );
            _scheduleStateRefresh();
          }
          break;
        case 'execution':
          if (actorId == _myUserId) {
            state = state.copyWith(
              myState: state.myState.copyWith(
                executionArmedUntil: (result['armedUntil'] as num?)?.toInt(),
              ),
            );
            _scheduleStateRefresh();
          }
          break;
      }
    }));

    _subs.add(_socket.onFwDuelChallenged.listen((data) {
      if (data['self'] == true) {
        return;
      }
      state = state.copyWith(
        duel: FwDuelState(
          duelId: data['duelId'] as String?,
          opponentId: data['challengerId'] as String?,
          phase: 'challenged',
        ),
      );
    }));

    _subs.add(_socket.onFwDuelAccepted.listen((data) {
      if (state.duel.phase != 'challenging') {
        return;
      }
      state = state.copyWith(
        duel: state.duel.copyWith(
          duelId: data['duelId'] as String? ?? state.duel.duelId,
        ),
      );
    }));

    _subs.add(_socket.onFwDuelRejected.listen((_) {
      state = state.copyWith(duel: const FwDuelState());
    }));

    _subs.add(_socket.onFwDuelCancelled.listen((_) {
      state = state.copyWith(duel: const FwDuelState());
    }));

    _subs.add(_socket.onFwDuelStarted.listen((data) {
      final rawParams = data['params'];
      final params = rawParams is Map
          ? Map<String, dynamic>.from(rawParams)
          : <String, dynamic>{};
      state = state.copyWith(
        duel: FwDuelState(
          duelId: data['duelId'] as String?,
          opponentId: state.duel.opponentId,
          phase: 'in_game',
          minigameType: data['minigameType'] as String?,
          minigameParams: params,
        ),
        myState: state.myState.copyWith(
          inDuel: true,
          duelExpiresAt: (data['startedAt'] as num?)?.toInt() == null
              ? state.myState.duelExpiresAt
              : ((data['startedAt'] as num).toInt() +
                  ((data['gameTimeoutMs'] as num?)?.toInt() ?? 30000)),
        ),
      );
    }));

    _subs.add(_socket.onFwDuelResult.listen((data) {
      final result = FwDuelResult.fromMap(data);
      _duelResultClearTimer?.cancel();
      state = state.copyWith(
        duel: state.duel.copyWith(
          phase: 'result',
          duelResult: result,
        ),
        myState: state.myState.copyWith(
          inDuel: false,
          duelExpiresAt: null,
        ),
      );
      _scheduleStateRefresh();
      _duelResultClearTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) {
          clearDuelResult();
        }
      });
    }));

    _subs.add(_socket.onFwDuelInvalidated.listen((_) {
      _duelResultClearTimer?.cancel();
      state = state.copyWith(
        duel: state.duel.copyWith(
          phase: 'invalidated',
          duelResult: FwDuelResult.invalidated(),
        ),
        myState: state.myState.copyWith(
          inDuel: false,
          duelExpiresAt: null,
        ),
      );
      _scheduleStateRefresh();
      _duelResultClearTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) {
          clearDuelResult();
        }
      });
    }));
  }

  void _handleStateUpdate(Map<String, dynamic> data) {
    final sessionId = data['sessionId'] as String?;
    if (sessionId != null && sessionId != _sessionId) {
      return;
    }

    final guildRaw = data['guilds'] as Map? ?? const {};
    final guilds = <String, FwGuildInfo>{};
    guildRaw.forEach((key, value) {
      if (value is Map) {
        guilds[key as String] =
            FwGuildInfo.fromMap(Map<String, dynamic>.from(value));
      }
    });

    final controlPointRaw = data['controlPoints'] as List? ?? const [];
    final controlPoints = controlPointRaw
        .whereType<Map>()
        .map(
            (value) => FwControlPoint.fromMap(Map<String, dynamic>.from(value)))
        .toList();

    final playableAreaRaw = data['playableArea'] as List? ?? const [];
    final playableArea = playableAreaRaw
        .whereType<Map>()
        .map((value) => FwGeoPoint.fromMap(Map<String, dynamic>.from(value)))
        .toList();

    final spawnZoneRaw = data['spawnZones'] as List? ?? const [];
    final spawnZones = spawnZoneRaw
        .whereType<Map>()
        .map((value) => FwSpawnZone.fromMap(Map<String, dynamic>.from(value)))
        .toList();

    final dungeonRaw = data['dungeons'] as List? ?? const [];
    final dungeons = dungeonRaw
        .whereType<Map>()
        .map(
            (value) => FwDungeonState.fromMap(Map<String, dynamic>.from(value)))
        .toList();

    final hasGuilds = data.containsKey('guilds');
    final hasControlPoints = data.containsKey('controlPoints');
    final hasPlayableArea = data.containsKey('playableArea');
    final hasSpawnZones = data.containsKey('spawnZones');
    final hasDungeons = data.containsKey('dungeons');
    final hasAlivePlayerIds = data.containsKey('alivePlayerIds');
    final hasEliminatedPlayerIds = data.containsKey('eliminatedPlayerIds');
    final hasWinCondition = data.containsKey('winCondition');

    var nextState = state.copyWith(
      status: data['status'] as String? ?? state.status,
      guilds: hasGuilds ? guilds : state.guilds,
      controlPoints: hasControlPoints ? controlPoints : state.controlPoints,
      playableArea: hasPlayableArea ? playableArea : state.playableArea,
      spawnZones: hasSpawnZones ? spawnZones : state.spawnZones,
      dungeons: hasDungeons ? dungeons : state.dungeons,
      alivePlayerIds: hasAlivePlayerIds
          ? (data['alivePlayerIds'] as List?)?.whereType<String>().toList() ??
              const []
          : state.alivePlayerIds,
      eliminatedPlayerIds: hasEliminatedPlayerIds
          ? (data['eliminatedPlayerIds'] as List?)
                  ?.whereType<String>()
                  .toList() ??
              const []
          : state.eliminatedPlayerIds,
      winCondition: hasWinCondition
          ? (data['winCondition'] is Map
              ? Map<String, dynamic>.from(data['winCondition'] as Map)
              : null)
          : state.winCondition,
    );

    if (data.containsKey('guildId')) {
      nextState = nextState.copyWith(
        myState: _parseMyState(nextState.myState, data),
      );
    }

    state = nextState;
  }

  FwMyState _parseMyState(FwMyState current, Map<String, dynamic> data) {
    final rawSkillUsedAt =
        (data['skillUsedAt'] as Map?)?.cast<String, dynamic>() ?? const {};
    final skillUsedAt = <String, int>{};
    rawSkillUsedAt.forEach((skill, usedAt) {
      final lastUsedAt = (usedAt as num?)?.toInt();
      if (lastUsedAt == null) {
        return;
      }
      skillUsedAt[skill] = lastUsedAt + _cooldownMsForSkill(skill);
    });

    final hasSkillUsedAt = data.containsKey('skillUsedAt');
    final shields = data['shields'];
    final shieldCount = shields is List ? shields.length : current.shieldCount;
    final isAlive = data['isAlive'] as bool? ?? current.isAlive;
    final nextReviveChance = (data['nextReviveChance'] as num?)?.toDouble();
    final dungeonEntered = data['dungeonEntered'] as bool?;

    return current.copyWith(
      guildId: data['guildId'] as String?,
      job: data['job'] as String?,
      isGuildMaster: data['isGuildMaster'] as bool? ?? current.isGuildMaster,
      isAlive: isAlive,
      hp: (data['hp'] as num?)?.toInt() ?? current.hp,
      remainingLives:
          (data['remainingLives'] as num?)?.toInt() ?? current.remainingLives,
      shieldCount: shieldCount,
      captureZone: data['captureZone'] as String?,
      inDuel: data['inDuel'] as bool? ?? current.inDuel,
      duelExpiresAt: (data['duelExpiresAt'] as num?)?.toInt(),
      executionArmedUntil: (data['executionArmedUntil'] as num?)?.toInt(),
      buffedUntil: (data['buffedUntil'] as num?)?.toInt(),
      revealUntil: (data['revealUntil'] as num?)?.toInt(),
      trackedTargetUserId: data['trackedTargetUserId'] as String?,
      dungeonEntered:
          dungeonEntered ?? (!isAlive ? current.dungeonEntered : false),
      nextReviveChance:
          isAlive ? null : (nextReviveChance ?? current.nextReviveChance),
      skillUsedAt: hasSkillUsedAt ? skillUsedAt : current.skillUsedAt,
    );
  }

  void _requestStateNow() {
    _stateRefreshTimer?.cancel();
    if (_socket.isConnected) {
      _socket.requestGameState(_sessionId);
    }
  }

  void refreshState() => _requestStateNow();

  void _scheduleStateRefresh(
      [Duration delay = const Duration(milliseconds: 120)]) {
    _stateRefreshTimer?.cancel();
    _stateRefreshTimer = Timer(delay, () {
      if (mounted && _socket.isConnected) {
        _socket.requestGameState(_sessionId);
      }
    });
  }

  String? _guildIdForUser(String userId) {
    for (final guild in state.guilds.values) {
      if (guild.memberIds.contains(userId)) {
        return guild.guildId;
      }
    }
    return null;
  }

  void _mutateControlPoint(
    String? controlPointId,
    FwControlPoint Function(FwControlPoint current) update,
  ) {
    if (controlPointId == null) {
      return;
    }

    state = state.copyWith(
      controlPoints: state.controlPoints
          .map((controlPoint) => controlPoint.id == controlPointId
              ? update(controlPoint)
              : controlPoint)
          .toList(),
    );
  }

  Future<Map<String, dynamic>> startCapture(String controlPointId) async {
    final result = await _socket.sendFwCaptureStart(_sessionId, controlPointId);
    if (result['ok'] == true) {
      _scheduleStateRefresh();
    }
    return result;
  }

  Future<Map<String, dynamic>> cancelCapture(String controlPointId) async {
    final result =
        await _socket.sendFwCaptureCancel(_sessionId, controlPointId);
    if (result['ok'] == true) {
      _scheduleStateRefresh();
    }
    return result;
  }

  Future<Map<String, dynamic>> enterDungeon(
      {String dungeonId = 'dungeon_main'}) async {
    final result =
        await _socket.sendFwDungeonEnter(_sessionId, dungeonId: dungeonId);
    if (result['ok'] == true) {
      state = state.copyWith(
        myState: state.myState.copyWith(
          dungeonEntered: true,
          nextReviveChance: state.myState.nextReviveChance ?? 0.3,
        ),
      );
      _scheduleStateRefresh();
    }
    return result;
  }

  Future<Map<String, dynamic>> useSkill({
    String? targetUserId,
    String? controlPointId,
  }) async {
    final job = state.myState.job;
    if (job == null) {
      return {'ok': false, 'error': 'NO_JOB'};
    }

    final skill = switch (job) {
      'priest' => 'shield',
      'mage' => 'blockade',
      'ranger' => 'reveal',
      'rogue' => 'execution',
      _ => null,
    };
    if (skill == null) {
      return {'ok': false, 'error': 'NO_ACTIVE_SKILL'};
    }

    final result = await _socket.sendFwUseSkill(
      _sessionId,
      skill: skill,
      targetUserId: targetUserId,
      controlPointId: controlPointId,
    );
    if (result['ok'] == true) {
      _scheduleStateRefresh();
    }
    return result;
  }

  Future<Map<String, dynamic>> challengeDuel(String targetUserId) async {
    final result = await _socket.sendDuelChallenge(_sessionId, targetUserId);
    if (result['ok'] == true) {
      state = state.copyWith(
        duel: FwDuelState(
          duelId: result['duelId'] as String?,
          opponentId: targetUserId,
          phase: 'challenging',
        ),
      );
    }
    return result;
  }

  Future<Map<String, dynamic>> acceptDuel(String duelId) =>
      _socket.sendDuelAccept(duelId);

  Future<Map<String, dynamic>> rejectDuel(String duelId) async {
    final result = await _socket.sendDuelReject(duelId);
    if (result['ok'] == true) {
      state = state.copyWith(duel: const FwDuelState());
    }
    return result;
  }

  Future<Map<String, dynamic>> cancelDuel() async {
    final duelId = state.duel.duelId;
    if (duelId == null) {
      state = state.copyWith(duel: const FwDuelState());
      return {'ok': true};
    }

    final result = await _socket.sendDuelCancel(duelId);
    if (result['ok'] == true) {
      state = state.copyWith(duel: const FwDuelState());
    }
    return result;
  }

  Future<Map<String, dynamic>> submitMinigame(
      Map<String, dynamic> result) async {
    final duelId = state.duel.duelId;
    if (duelId == null || state.duel.submitted) {
      return {'ok': false, 'error': 'DUEL_NOT_ACTIVE'};
    }

    final response = await _socket.sendDuelSubmit(duelId, result);
    if (response['ok'] == true) {
      state = state.copyWith(
        duel: state.duel.copyWith(submitted: true),
      );
    }
    return response;
  }

  void clearDuelResult() {
    if (!mounted) {
      return;
    }
    state = state.copyWith(duel: const FwDuelState());
  }

  int _cooldownMsForSkill(String skill) => switch (skill) {
        'shield' => 600000,
        'blockade' => 600000,
        'reveal' => 300000,
        'execution' => 600000,
        _ => 0,
      };

  @override
  void dispose() {
    _duelResultClearTimer?.cancel();
    _stateRefreshTimer?.cancel();
    for (final subscription in _subs) {
      subscription.cancel();
    }
    super.dispose();
  }
}
