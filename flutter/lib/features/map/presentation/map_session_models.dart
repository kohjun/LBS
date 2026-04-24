import 'package:geolocator/geolocator.dart';

class MemberState {
  final String userId;
  final String nickname;
  final double lat;
  final double lng;
  final int? battery;
  final String status;
  final String role;
  final bool sharingEnabled;
  final DateTime updatedAt;

  const MemberState({
    required this.userId,
    required this.nickname,
    required this.lat,
    required this.lng,
    this.battery,
    required this.status,
    this.role = 'member',
    this.sharingEnabled = true,
    required this.updatedAt,
  });

  MemberState copyWith({
    double? lat,
    double? lng,
    int? battery,
    String? status,
    String? role,
    bool? sharingEnabled,
    DateTime? updatedAt,
  }) =>
      MemberState(
        userId: userId,
        nickname: nickname,
        lat: lat ?? this.lat,
        lng: lng ?? this.lng,
        battery: battery ?? this.battery,
        status: status ?? this.status,
        role: role ?? this.role,
        sharingEnabled: sharingEnabled ?? this.sharingEnabled,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

class BleMemberContact {
  final String userId;
  final int rssi;
  final int seenAtMs;
  final String deviceId;

  const BleMemberContact({
    required this.userId,
    required this.rssi,
    required this.seenAtMs,
    required this.deviceId,
  });

  BleMemberContact copyWith({
    int? rssi,
    int? seenAtMs,
    String? deviceId,
  }) =>
      BleMemberContact(
        userId: userId,
        rssi: rssi ?? this.rssi,
        seenAtMs: seenAtMs ?? this.seenAtMs,
        deviceId: deviceId ?? this.deviceId,
      );
}

class GameState {
  final String? gameType;
  final String status;
  final int aliveCount;
  final List<String> alivePlayerIds;
  final String? winnerId;
  final String? taggerId;
  final int? roundNumber;
  final int? incompleteMissionCount;

  const GameState({
    this.gameType,
    this.status = 'none',
    this.aliveCount = 0,
    this.alivePlayerIds = const [],
    this.winnerId,
    this.taggerId,
    this.roundNumber,
    this.incompleteMissionCount,
  });

  factory GameState.fromMap(Map<String, dynamic> data) => GameState(
        gameType: data['gameType'] as String?,
        status: data['status'] as String? ?? 'none',
        aliveCount: data['aliveCount'] as int? ?? 0,
        alivePlayerIds: (data['alivePlayerIds'] as List<dynamic>?)
                ?.whereType<String>()
                .toList() ??
            const [],
        winnerId: data['winnerId'] as String?,
        taggerId: data['taggerId'] as String?,
        roundNumber: data['roundNumber'] as int?,
        incompleteMissionCount: data['incompleteMissionCount'] as int?,
      );
}

class MapSessionState {
  final Map<String, MemberState> members;
  final Map<String, BleMemberContact> bleContacts;
  final String blePresenceStatus;
  final String? blePresenceMessage;
  final Position? myPosition;
  final bool isConnected;
  final bool sosTriggered;
  final String? sessionName;
  final bool sharingEnabled;
  final Set<String> hiddenMembers;
  final bool wasKicked;
  final String myRole;
  final bool isEliminated;
  final Set<String> eliminatedUserIds;
  final Map<String, double> memberDistances;
  final String? proximateTargetId;
  final GameState gameState;
  final bool hasEverConnected;

  const MapSessionState({
    required this.members,
    this.bleContacts = const {},
    this.blePresenceStatus = 'idle',
    this.blePresenceMessage,
    this.myPosition,
    this.isConnected = false,
    this.hasEverConnected = false,
    this.sosTriggered = false,
    this.sessionName,
    this.sharingEnabled = true,
    this.hiddenMembers = const {},
    this.wasKicked = false,
    this.myRole = 'member',
    this.isEliminated = false,
    this.eliminatedUserIds = const {},
    this.memberDistances = const {},
    this.proximateTargetId,
    this.gameState = const GameState(),
  });

  MapSessionState copyWith({
    Map<String, MemberState>? members,
    Map<String, BleMemberContact>? bleContacts,
    String? blePresenceStatus,
    Object? blePresenceMessage = _sentinel,
    Position? myPosition,
    bool? isConnected,
    bool? hasEverConnected,
    bool? sosTriggered,
    String? sessionName,
    bool? sharingEnabled,
    Set<String>? hiddenMembers,
    bool? wasKicked,
    String? myRole,
    bool? isEliminated,
    Set<String>? eliminatedUserIds,
    Map<String, double>? memberDistances,
    Object? proximateTargetId = _sentinel,
    GameState? gameState,
  }) =>
      MapSessionState(
        members: members ?? this.members,
        bleContacts: bleContacts ?? this.bleContacts,
        blePresenceStatus: blePresenceStatus ?? this.blePresenceStatus,
        blePresenceMessage: blePresenceMessage == _sentinel
            ? this.blePresenceMessage
            : blePresenceMessage as String?,
        myPosition: myPosition ?? this.myPosition,
        isConnected: isConnected ?? this.isConnected,
        hasEverConnected: hasEverConnected ?? this.hasEverConnected,
        sosTriggered: sosTriggered ?? this.sosTriggered,
        sessionName: sessionName ?? this.sessionName,
        sharingEnabled: sharingEnabled ?? this.sharingEnabled,
        hiddenMembers: hiddenMembers ?? this.hiddenMembers,
        wasKicked: wasKicked ?? this.wasKicked,
        myRole: myRole ?? this.myRole,
        isEliminated: isEliminated ?? this.isEliminated,
        eliminatedUserIds: eliminatedUserIds ?? this.eliminatedUserIds,
        memberDistances: memberDistances ?? this.memberDistances,
        proximateTargetId: proximateTargetId == _sentinel
            ? this.proximateTargetId
            : proximateTargetId as String?,
        gameState: gameState ?? this.gameState,
      );
}

const Object _sentinel = Object();
