// lib/core/services/socket_service.dart

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import '../network/api_client.dart';

const _wsUrl = 'http://10.0.2.2:3000';

// ─────────────────────────────────────────────────────────────────────────────
// 위치 데이터 모델
// ─────────────────────────────────────────────────────────────────────────────
class LocationPayload {
  final String userId;
  final String? nickname;
  final double lat;
  final double lng;
  final double? accuracy;
  final double? speed;
  final double? heading;
  final String source;
  final int? battery;
  final String status;
  final int ts;

  const LocationPayload({
    required this.userId,
    this.nickname,
    required this.lat,
    required this.lng,
    this.accuracy,
    this.speed,
    this.heading,
    this.source = 'gps',
    this.battery,
    this.status = 'moving',
    required this.ts,
  });

  factory LocationPayload.fromMap(Map<String, dynamic> map) => LocationPayload(
        userId: map['userId'] as String,
        nickname: map['nickname'] as String?,
        lat: (map['lat'] as num).toDouble(),
        lng: (map['lng'] as num).toDouble(),
        accuracy: (map['accuracy'] as num?)?.toDouble(),
        speed: (map['speed'] as num?)?.toDouble(),
        heading: (map['heading'] as num?)?.toDouble(),
        source: map['source'] as String? ?? 'gps',
        battery: map['battery'] as int?,
        status: map['status'] as String? ?? 'moving',
        ts: map['ts'] as int? ?? DateTime.now().millisecondsSinceEpoch,
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Socket 이벤트 상수 (백엔드 EVENTS와 동기화)
// ─────────────────────────────────────────────────────────────────────────────
class SocketEvents {
  // Client → Server
  static const joinSession = 'session:join';
  static const leaveSession = 'session:leave';
  static const locationUpdate = 'location:update';
  static const statusUpdate = 'status:update';
  static const sosTrigger = 'sos:trigger';
  static const actionInteract = 'action:interact';

  // Server → Client
  static const sessionJoined = 'session:joined';
  static const memberJoined = 'member:joined';
  static const memberLeft = 'member:left';
  static const locationChanged = 'location:changed';
  static const statusChanged = 'status:changed';
  static const sosAlert = 'sos:alert';
  static const sessionSnapshot = 'session:snapshot';
  static const kicked = 'kicked';
  static const roleChanged = 'role_changed';
  static const error = 'error';
  // 추가됨: 세션 만료 이벤트
  static const sessionExpired = 'sessionExpired';
  // 근접 제거 이벤트
  static const proximityKilled = 'proximity:killed';
  // 세션 전체 탈락 브로드캐스트
  static const playerEliminated = 'player:eliminated';
  // 게임 라이프사이클
  static const gameStart = 'game:start';
  static const gameStarted = 'game:started';
  static const gameRequestState = 'game:request_state';
  static const gameStateUpdate = 'game:state_update';
  static const gameOver = 'game:over';
}

// ─────────────────────────────────────────────────────────────────────────────
// SocketService - 싱글톤
// ─────────────────────────────────────────────────────────────────────────────
class SocketService {
  io.Socket? _socket;
  bool _isConnected = false;
  String? _currentSessionId;

  // ── 지수 백오프 재연결 ────────────────────────────────────────────────────
  int _reconnectAttempts = 0;
  bool _reconnectScheduled = false;
  Timer? _reconnectTimer;
  static const _baseDelayMs = 3000; // 초기 대기 시간: 3s
  static const _maxDelayMs = 30000; // 최대 대기 시간: 30s
  static const _maxReconnectAttempts = 3; // 최대 재연결 횟수

  // 스트림 컨트롤러 (UI 레이어에서 구독)
  final _locationController = StreamController<LocationPayload>.broadcast();
  final _memberJoinController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _memberLeftController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _statusController = StreamController<Map<String, dynamic>>.broadcast();
  final _sosController = StreamController<Map<String, dynamic>>.broadcast();
  final _snapshotController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _connectionController = StreamController<bool>.broadcast();
  final _kickedController = StreamController<Map<String, dynamic>>.broadcast();
  final _roleChangedController =
      StreamController<Map<String, dynamic>>.broadcast();

  // 추가됨: 세션 만료 스트림 컨트롤러
  final _sessionExpiredController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _proximityKilledController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _playerEliminatedController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _gameStateController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _gameOverController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _gameStartedController =
      StreamController<Map<String, dynamic>>.broadcast();
  final Map<String, StreamController<Map<String, dynamic>>>
      _gameEventControllers = {};

  Stream<LocationPayload> get onLocationChanged => _locationController.stream;
  Stream<Map<String, dynamic>> get onMemberJoined =>
      _memberJoinController.stream;
  Stream<Map<String, dynamic>> get onMemberLeft => _memberLeftController.stream;
  Stream<Map<String, dynamic>> get onStatusChanged => _statusController.stream;
  Stream<Map<String, dynamic>> get onSosAlert => _sosController.stream;
  Stream<Map<String, dynamic>> get onSnapshot => _snapshotController.stream;
  Stream<bool> get onConnectionChange => _connectionController.stream;
  Stream<Map<String, dynamic>> get onKicked => _kickedController.stream;
  Stream<Map<String, dynamic>> get onRoleChanged =>
      _roleChangedController.stream;

  // 추가됨: 세션 만료 스트림 getter
  Stream<Map<String, dynamic>> get onSessionExpired =>
      _sessionExpiredController.stream;
  Stream<Map<String, dynamic>> get onProximityKilled =>
      _proximityKilledController.stream;
  Stream<Map<String, dynamic>> get onPlayerEliminated =>
      _playerEliminatedController.stream;
  Stream<Map<String, dynamic>> get onGameStateUpdate =>
      _gameStateController.stream;
  Stream<Map<String, dynamic>> get onGameOver => _gameOverController.stream;
  Stream<Map<String, dynamic>> get onGameStarted =>
      _gameStartedController.stream;

  bool get isConnected => _isConnected;

  static final SocketService _instance = SocketService._internal();
  factory SocketService() => _instance;
  SocketService._internal();

  StreamController<Map<String, dynamic>> _controllerForGameEvent(String event) {
    return _gameEventControllers.putIfAbsent(
      event,
      () => StreamController<Map<String, dynamic>>.broadcast(),
    );
  }

  void _emitGameEvent(String event, dynamic data) {
    if (data is! Map) return;
    final controller = _gameEventControllers[event];
    if (controller == null || controller.isClosed) return;
    controller.add(Map<String, dynamic>.from(data));
  }

  // ─────────────────────────────────────────────────────────────────────────
  // WebSocket 연결 (Access Token 전달)
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> connect() async {
    if (_isConnected) return;

    final token = await ApiClient().getAccessToken();
    if (token == null) throw Exception('NOT_AUTHENTICATED');

    _socket = io.io(
      _wsUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect() // 핸들러 등록 후 수동 연결
          .disableReconnection() // socket.io 내장 재연결 비활성화 → 직접 관리
          .setExtraHeaders({'Authorization': 'Bearer $token'})
          .setAuth({'token': token})
          .build(),
    );

    _registerEventHandlers();
    _socket!.connect(); // 핸들러 등록 후 연결 시작
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 이벤트 핸들러 등록
  // ─────────────────────────────────────────────────────────────────────────
  void _registerEventHandlers() {
    _socket!
      ..onConnect((_) {
        _isConnected = true;
        _reconnectAttempts = 0; // 성공 시 카운터 초기화
        _reconnectScheduled = false;
        _reconnectTimer?.cancel();
        _connectionController.add(true);
        debugPrint('[Socket] Connected');
      })
      ..onDisconnect((reason) {
        _isConnected = false;
        _connectionController.add(false);
        debugPrint('[Socket] Disconnected: $reason');
        // 클라이언트 측 수동 해제가 아닐 때만 재연결 시도
        if (reason != 'io client disconnect') {
          _scheduleReconnect();
        }
      })
      ..onConnectError((err) {
        debugPrint('[Socket] Connect error: $err');
        _scheduleReconnect();
      })

      // 다른 멤버 위치 수신
      ..on(SocketEvents.locationChanged, (data) {
        try {
          final payload =
              LocationPayload.fromMap(Map<String, dynamic>.from(data));
          _locationController.add(payload);
        } catch (e) {
          debugPrint('[Socket] locationChanged parse error: $e');
        }
      })

      // 멤버 입장/퇴장
      ..on(SocketEvents.memberJoined,
          (data) => _memberJoinController.add(Map<String, dynamic>.from(data)))
      ..on(SocketEvents.memberLeft,
          (data) => _memberLeftController.add(Map<String, dynamic>.from(data)))

      // 상태 변경
      ..on(SocketEvents.statusChanged,
          (data) => _statusController.add(Map<String, dynamic>.from(data)))

      // SOS 알림
      ..on(SocketEvents.sosAlert,
          (data) => _sosController.add(Map<String, dynamic>.from(data)))

      // 세션 참가 시 전체 스냅샷
      ..on(SocketEvents.sessionSnapshot,
          (data) => _snapshotController.add(Map<String, dynamic>.from(data)))

      // 강제 퇴장
      ..on(
          SocketEvents.kicked,
          (data) => _kickedController
              .add(Map<String, dynamic>.from(data as Map? ?? {})))

      // 역할 변경 브로드캐스트
      ..on(
          SocketEvents.roleChanged,
          (data) => _roleChangedController
              .add(Map<String, dynamic>.from(data as Map? ?? {})))

      // 추가됨: 세션 만료 수신
      ..on(
          SocketEvents.sessionExpired,
          (data) => _sessionExpiredController
              .add(Map<String, dynamic>.from(data as Map? ?? {})))

      // 근접 제거 수신
      ..on(
          SocketEvents.proximityKilled,
          (data) => _proximityKilledController
              .add(Map<String, dynamic>.from(data as Map? ?? {})))

      // 세션 전체 탈락 브로드캐스트
      ..on(
          SocketEvents.playerEliminated,
          (data) => _playerEliminatedController
              .add(Map<String, dynamic>.from(data as Map? ?? {})))

      // 게임 상태 갱신
      ..on(
          SocketEvents.gameStateUpdate,
          (data) => _gameStateController
              .add(Map<String, dynamic>.from(data as Map? ?? {})))

      // 게임 종료
      ..on(
          SocketEvents.gameOver,
          (data) => _gameOverController
              .add(Map<String, dynamic>.from(data as Map? ?? {})))
      ..on(gameStarted, (data) {
        _emitGameEvent(gameStarted, data);
        if (data is Map) {
          _gameStartedController.add(Map<String, dynamic>.from(data));
        }
      })
      ..on(gameRoleAssigned, (data) => _emitGameEvent(gameRoleAssigned, data))
      ..on(gameKillConfirmed, (data) => _emitGameEvent(gameKillConfirmed, data))
      ..on(gameBodyFound, (data) => _emitGameEvent(gameBodyFound, data))
      ..on(gameMeetingStarted,
          (data) => _emitGameEvent(gameMeetingStarted, data))
      ..on(gameMeetingTick, (data) => _emitGameEvent(gameMeetingTick, data))
      ..on(gameVotingStarted, (data) => _emitGameEvent(gameVotingStarted, data))
      ..on(gameVoteSubmitted, (data) => _emitGameEvent(gameVoteSubmitted, data))
      ..on(gamePreVoteSubmitted,
          (data) => _emitGameEvent(gamePreVoteSubmitted, data))
      ..on(gameVoteResult, (data) => _emitGameEvent(gameVoteResult, data))
      ..on(gameMeetingEnded, (data) => _emitGameEvent(gameMeetingEnded, data))
      ..on(gameAiMessage, (data) => _emitGameEvent(gameAiMessage, data))
      ..on(gameAiReply, (data) => _emitGameEvent(gameAiReply, data))
      ..on(gameMissionProgress,
          (data) => _emitGameEvent(gameMissionProgress, data));
  }

  // ... (아래 joinSession, sendLocation 등 나머지 코드는 기존과 완벽히 동일하므로 생략하지 않고 그대로 유지하세요) ...

  // ─────────────────────────────────────────────────────────────────────────
  // 세션 참가
  // ─────────────────────────────────────────────────────────────────────────
  void joinSession(String sessionId) {
    _currentSessionId = sessionId;
    _socket?.emit(SocketEvents.joinSession, {'sessionId': sessionId});
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 내 위치 전송 (GPS / BLE / UWB 공통)
  // ─────────────────────────────────────────────────────────────────────────
  void sendLocation({
    required double lat,
    required double lng,
    double? accuracy,
    double? altitude,
    double? speed,
    double? heading,
    String source = 'gps',
    int? battery,
    String status = 'moving',
  }) {
    if (!_isConnected || _currentSessionId == null) return;

    _socket?.emit(SocketEvents.locationUpdate, {
      'sessionId': _currentSessionId,
      'lat': lat,
      'lng': lng,
      'accuracy': accuracy,
      'altitude': altitude,
      'speed': speed,
      'heading': heading,
      'source': source,
      'battery': battery,
      'status': status,
    });
  }

  // 세션 ID를 명시적으로 전달하는 위치 전송 (location_service 전용)
  void sendLocationWithSession({
    required String sessionId,
    required double lat,
    required double lng,
    double? accuracy,
    double? altitude,
    double? speed,
    double? heading,
    String source = 'gps',
    int? battery,
    String status = 'moving',
  }) {
    if (!_isConnected) return;

    _socket?.emit(SocketEvents.locationUpdate, {
      'sessionId': sessionId,
      'lat': lat,
      'lng': lng,
      'accuracy': accuracy,
      'altitude': altitude,
      'speed': speed,
      'heading': heading,
      'source': source,
      'battery': battery,
      'status': status,
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SOS 발송
  // ─────────────────────────────────────────────────────────────────────────
  void sendSOS({double? lat, double? lng, String? message}) {
    if (!_isConnected || _currentSessionId == null) return;

    _socket?.emit(SocketEvents.sosTrigger, {
      'sessionId': _currentSessionId,
      'lat': lat,
      'lng': lng,
      'message': message ?? '긴급 상황 발생!',
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 상태 업데이트 (이동중/정지/SOS)
  // ─────────────────────────────────────────────────────────────────────────
  void updateStatus(String status, {int? battery}) {
    _socket?.emit(SocketEvents.statusUpdate, {
      'sessionId': _currentSessionId,
      'status': status,
      'battery': battery,
    });
  }

  void emitGameStart(String sessionId) {
    if (!_isConnected) return;
    _socket?.emit(SocketEvents.gameStart, {'sessionId': sessionId});
  }

  void emitVoteOpen(String sessionId, Function(Map) callback) {
    if (!_isConnected) {
      callback({'ok': false, 'error': 'SOCKET_DISCONNECTED'});
      return;
    }

    _socket?.emitWithAck(
      'game:emergency',
      {'sessionId': sessionId},
      ack: (data) => callback(
        data is Map ? Map<String, dynamic>.from(data) : {'ok': false},
      ),
    );
  }

  void requestGameState(String sessionId) {
    if (!_isConnected) return;
    _socket?.emit(SocketEvents.gameRequestState, {'sessionId': sessionId});
  }

  void interactAction({
    required String sessionId,
    required String actionType,
    required String targetUserId,
  }) {
    if (!_isConnected) return;
    _socket?.emit(SocketEvents.actionInteract, {
      'sessionId': sessionId,
      'actionType': actionType,
      'targetUserId': targetUserId,
    });
  }

  void sendLocationUpdate(
      String sessionId, double lat, double lng, String status) {
    _socket?.emit(SocketEvents.locationUpdate, {
      'sessionId': sessionId,
      'lat': lat,
      'lng': lng,
      'status': status,
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 지수 백오프 재연결 스케줄러
  // ─────────────────────────────────────────────────────────────────────────
  void _scheduleReconnect() {
    if (_reconnectScheduled) return;
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      debugPrint('[Socket] 최대 재연결 횟수 초과 ($_maxReconnectAttempts회)');
      return;
    }
    _reconnectScheduled = true;

    final delayMs = math.min(
      _baseDelayMs * math.pow(2, _reconnectAttempts).toInt(),
      _maxDelayMs,
    );
    debugPrint(
        '[Socket] 재연결 예약: ${delayMs}ms 후 (시도 ${_reconnectAttempts + 1}/$_maxReconnectAttempts)');

    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      _reconnectScheduled = false;
      _reconnectAttempts++;
      _socket?.connect();
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 연결 해제
  // ─────────────────────────────────────────────────────────────────────────
  void disconnect() {
    _reconnectTimer?.cancel();
    _reconnectAttempts = 0;
    _reconnectScheduled = false;
    _socket?.disconnect();
    _socket = null;
    _isConnected = false;
    _currentSessionId = null;
  }

  void dispose() {
    _reconnectTimer?.cancel();
    disconnect();
    _locationController.close();
    _memberJoinController.close();
    _memberLeftController.close();
    _statusController.close();
    _sosController.close();
    _snapshotController.close();
    _connectionController.close();
    _kickedController.close();
    _roleChangedController.close();
    _sessionExpiredController.close();
    _proximityKilledController.close();
    _playerEliminatedController.close();
    _gameStateController.close();
    _gameOverController.close();
    _gameStartedController.close();
    for (final controller in _gameEventControllers.values) {
      controller.close();
    }
    _gameEventControllers.clear();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 게임 이벤트 상수 (Among Us 플러그인)
  // ─────────────────────────────────────────────────────────────────────────
  static const String gameStarted = 'game:started';
  static const String gameRoleAssigned = 'game:role_assigned';
  static const String gameKillConfirmed = 'game:kill_confirmed';
  static const String gameBodyFound = 'game:body_found';
  static const String gameMeetingStarted = 'game:meeting_started';
  static const String gameMeetingTick = 'game:meeting_tick';
  static const String gameVotingStarted = 'game:voting_started';
  static const String gameVoteSubmitted = 'game:vote_submitted';
  static const String gamePreVoteSubmitted = 'game:pre_vote_submitted';
  static const String gameVoteResult = 'game:vote_result';
  static const String gameMeetingEnded = 'game:meeting_ended';
  static const String gameAiMessage = 'game:ai_message';
  static const String gameAiReply = 'game:ai_reply';
  static const String gameMissionProgress = 'game:mission_progress';
  static const String gameOver = 'game:over';

  // ─────────────────────────────────────────────────────────────────────────
  // 게임 액션 메서드
  // ─────────────────────────────────────────────────────────────────────────
  void startGame(String sessionId) {
    _socket?.emit('game:start', {'sessionId': sessionId});
  }

  void sendKill(String sessionId, String targetUserId) {
    _socket?.emit(
        'game:kill', {'sessionId': sessionId, 'targetUserId': targetUserId});
  }

  void sendEmergencyMeeting(String sessionId, [Function(Map)? callback]) {
    if (callback == null) {
      _socket?.emit('game:emergency', {'sessionId': sessionId});
      return;
    }

    _socket?.emitWithAck(
      'game:emergency',
      {'sessionId': sessionId},
      ack: (data) => callback(
        data is Map ? Map<String, dynamic>.from(data) : {'ok': false},
      ),
    );
  }

  void sendReport(String sessionId, String bodyId) {
    _socket?.emit('game:report', {'sessionId': sessionId, 'bodyId': bodyId});
  }

  void sendVote(String sessionId, String targetId, Function(Map) callback) {
    _socket?.emitWithAck(
      'game:vote',
      {'sessionId': sessionId, 'targetId': targetId},
      ack: (data) => callback(data as Map),
    );
  }

  void sendMissionComplete(String sessionId, String missionId) {
    _socket?.emit('game:mission_complete',
        {'sessionId': sessionId, 'missionId': missionId});
  }

  void sendAiQuestion(
      String sessionId, String question, Function(Map) callback) {
    _socket?.emitWithAck(
      'game:ai_ask',
      {'sessionId': sessionId, 'question': question},
      ack: (data) => callback(data as Map),
    );
  }

  Stream<Map<String, dynamic>> onGameEvent(String event) {
    return _controllerForGameEvent(event).stream;
  }
}
