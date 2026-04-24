// lib/features/map/data/map_session_provider.dart
//
// MapSessionNotifier + mapSessionProvider
// (map_screen.dart에서 추출. 소켓/GPS/오디오/지오펜스 상태를 통합 관리)

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import '../../../core/services/background_service.dart';
import '../../../core/services/fantasy_wars_ble_presence_service.dart';
import '../../../core/services/mediasoup_audio_service.dart';
import '../../../core/services/socket_service.dart';
import '../../../core/services/location_service.dart';
import '../../../core/network/api_client.dart';
import '../../auth/data/auth_repository.dart';
import '../../home/data/session_repository.dart';
import '../../geofence/data/geofence_repository.dart';
import '../presentation/map_session_models.dart';

class MapSessionNotifier extends StateNotifier<MapSessionState> {
  MapSessionNotifier(this._sessionId, this._ref)
      : super(const MapSessionState(members: {})) {
    _init();
  }

  final String _sessionId;
  final Ref _ref;

  final _socket = SocketService();
  final _audio = MediaSoupAudioService();
  final _ble = FantasyWarsBlePresenceService();
  final _gps = GpsLocationService();

  StreamSubscription? _locationSub;
  StreamSubscription? _memberJoinSub;
  StreamSubscription? _memberLeftSub;
  StreamSubscription? _statusSub;
  StreamSubscription? _sosSub;
  StreamSubscription? _snapshotSub;
  StreamSubscription? _connectionSub;
  StreamSubscription? _myPositionSub;
  StreamSubscription? _kickedSub;
  StreamSubscription? _roleChangedSub;
  StreamSubscription? _sessionExpiredSub;
  StreamSubscription? _proximityKilledSub;
  StreamSubscription? _playerEliminatedSub;
  StreamSubscription? _gameStateSub;
  StreamSubscription? _gameOverSub;
  StreamSubscription? _bleSightingSub;
  StreamSubscription? _bleStatusSub;

  Timer? _joinRetryTimer;

  final Map<String, MemberState> _pendingUpdates = {};
  Timer? _markerFlushTimer;
  final Stopwatch _startupStopwatch = Stopwatch();
  bool _backgroundServiceStartRequested = false;

  final Set<String> _insideGeofences = {};
  List<dynamic> _currentGeofences = [];

  void _logStartupStep(String label) {}

  Future<void> _bootstrapSession(SharedPreferences prefs) async {
    await Future.microtask(() {});
    await _connectRealtime();
    _logStartupStep('connected realtime services');

    await Future.microtask(() {});
    await _startGpsTracking();
    _logStartupStep('started gps tracking');

    await Future.microtask(() {});
    await _loadInitialMembers();
    _logStartupStep('loaded initial members');

    unawaited(_prepareBackgroundService(prefs));
  }

  Future<void> _connectRealtime() async {
    try {
      await _socket.connect();
      if (_socket.isConnected) {
        state = state.copyWith(isConnected: true, hasEverConnected: true);
        _socket.joinSession(_sessionId);
        _socket.requestGameState(_sessionId);
        // mediasoup device load / transport 생성은 WebRTC 네이티브 호출이
        // 많아 메인 스레드에 부담을 준다. 맵 첫 프레임 이후로 밀어 초기
        // 렌더 구간과 겹치지 않게 한다.
        unawaited(() async {
          await WidgetsBinding.instance.endOfFrame;
          await Future<void>.delayed(const Duration(milliseconds: 400));
          if (!mounted) return;
          await _audio.ensureJoined(_sessionId);
        }());
      }
    } catch (e) {
      debugPrint('[Map] Socket connect failed: $e');
    }
  }

  // 백그라운드 서비스는 앱이 background로 내려갈 때만 시작한다.
  // startService()는 새 Flutter 엔진을 생성해 메인 스레드를 ~16초 블로킹하므로
  // 포그라운드에서는 절대 호출하지 않는다. 이 메서드는 설정(configure)만 수행한다.
  Future<void> _prepareBackgroundService(SharedPreferences prefs) async {
    if (_backgroundServiceStartRequested) return;
    _backgroundServiceStartRequested = true;

    try {
      await prefs.setString('bg_session_id', _sessionId);
      await prefs.setString('bg_server_url', kApiBaseUrl);

      final token = await ApiClient().getAccessToken();
      if (token != null) {
        await prefs.setString('bg_token', token);
      }

      await prefs.setBool('bg_active', true);
      await initializeBackgroundService();
    } catch (e) {
      debugPrint('[Background] Failed to configure background service: $e');
      _backgroundServiceStartRequested = false;
    }
  }

  Future<void> _init() async {
    _startupStopwatch.start();
    final cachedSessions = _ref.read(sessionListProvider).valueOrNull ?? [];
    final cached = cachedSessions.where((s) => s.id == _sessionId);

    if (cached.isNotEmpty) {
      state = state.copyWith(sessionName: cached.first.name);
    }

    final prefs = await SharedPreferences.getInstance();
    final hiddenList = prefs.getStringList('hidden_$_sessionId') ?? [];
    if (hiddenList.isNotEmpty) {
      state = state.copyWith(hiddenMembers: Set.from(hiddenList));
    }

    try {
      _currentGeofences =
          await _ref.read(geofenceRepositoryProvider).getGeofences(_sessionId);
    } catch (e) {
      debugPrint('[Map] 지오펜스 로드 실패: $e');
    }

    _bindSocketStreams();
    _bindBleStreams();
    _logStartupStep('restored cached state');

    unawaited(_bootstrapSession(prefs));

    _joinRetryTimer = Timer(const Duration(seconds: 30), () {
      if (mounted && state.members.isEmpty && state.isConnected) {
        _socket.joinSession(_sessionId);
      }
    });
  }

  void _bindSocketStreams() {
    _kickedSub = _socket.onKicked.listen((data) {
      state = state.copyWith(wasKicked: true);
    });

    _sessionExpiredSub = _socket.onSessionExpired.listen((data) {
      debugPrint('[Map] 세션 만료 수신: ${data['message']}');
      state = state.copyWith(wasKicked: true);
    });

    _proximityKilledSub = _socket.onProximityKilled.listen((data) {
      debugPrint('[Map] proximity:killed 수신 - killedBy: ${data['killedBy']}');
      state = state.copyWith(isEliminated: true);
    });

    _playerEliminatedSub = _socket.onPlayerEliminated.listen((data) {
      final eliminatedId = data['userId'] as String?;
      if (eliminatedId == null) return;
      debugPrint('[Map] player:eliminated 수신 - userId: $eliminatedId');
      state = state.copyWith(
        eliminatedUserIds: {...state.eliminatedUserIds, eliminatedId},
      );
    });

    _gameStateSub = _socket.onGameStateUpdate.listen((data) {
      state = state.copyWith(gameState: GameState.fromMap(data));
      unawaited(_syncBlePresenceLifecycle());
    });

    _gameOverSub = _socket.onGameOver.listen((data) {
      state = state.copyWith(
        gameState: GameState(
          status: 'finished',
          winnerId: data['winnerId'] as String?,
        ),
      );
      unawaited(_syncBlePresenceLifecycle());
    });

    _roleChangedSub = _socket.onRoleChanged.listen((data) {
      final userId = data['userId'] as String?;
      final role = data['role'] as String?;
      if (userId == null || role == null) return;
      final authUser = _ref.read(authProvider).valueOrNull;
      if (userId == authUser?.id) {
        state = state.copyWith(myRole: role);
      }
      final updated = Map<String, MemberState>.from(state.members);
      if (updated.containsKey(userId)) {
        updated[userId] = updated[userId]!.copyWith(role: role);
        state = state.copyWith(members: updated);
      }
    });

    _connectionSub = _socket.onConnectionChange.listen((connected) {
      state = state.copyWith(
        isConnected: connected,
        hasEverConnected: connected ? true : state.hasEverConnected,
      );
      unawaited(_syncBlePresenceLifecycle());
      if (connected) {
        _socket.joinSession(_sessionId);
        // Defer audio reconnect to avoid blocking map rendering on reconnection.
        unawaited(() async {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          if (!mounted) return;
          await _audio.ensureJoined(_sessionId);
        }());
      }
    });

    _markerFlushTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_pendingUpdates.isEmpty) return;
      final updated = Map<String, MemberState>.from(state.members)
        ..addAll(_pendingUpdates);
      _pendingUpdates.clear();
      state = state.copyWith(members: updated);
    });

    _locationSub = _socket.onLocationChanged.listen((payload) {
      final current =
          _pendingUpdates[payload.userId] ?? state.members[payload.userId];

      if (current != null && (current.lat != 0 || current.lng != 0)) {
        final dist = Geolocator.distanceBetween(
          current.lat,
          current.lng,
          payload.lat,
          payload.lng,
        );
        if (dist < 1) return; // 1m 미만 이동은 무시 (GPS 노이즈)
      }

      _pendingUpdates[payload.userId] = current != null
          ? current.copyWith(
              lat: payload.lat,
              lng: payload.lng,
              battery: payload.battery,
              status: payload.status,
              updatedAt: DateTime.now(),
            )
          : MemberState(
              userId: payload.userId,
              nickname: payload.nickname ?? payload.userId,
              lat: payload.lat,
              lng: payload.lng,
              battery: payload.battery,
              status: payload.status,
              updatedAt: DateTime.now(),
            );
    });

    _memberJoinSub = _socket.onMemberJoined.listen((data) {
      final userId = data['userId'] as String? ?? '';
      final nickname = data['nickname'] as String? ?? userId;
      final updated = Map<String, MemberState>.from(state.members);
      if (!updated.containsKey(userId)) {
        updated[userId] = MemberState(
          userId: userId,
          nickname: nickname,
          lat: 0,
          lng: 0,
          status: 'idle',
          updatedAt: DateTime.now(),
        );
        state = state.copyWith(members: updated);
      }
      unawaited(_syncBlePresenceLifecycle());
    });

    _memberLeftSub = _socket.onMemberLeft.listen((data) {
      final userId = data['userId'] as String? ?? '';
      final updated = Map<String, MemberState>.from(state.members)
        ..remove(userId);
      state = state.copyWith(members: updated);
      unawaited(_syncBlePresenceLifecycle());
    });

    _statusSub = _socket.onStatusChanged.listen((data) {
      final userId = data['userId'] as String? ?? '';
      final status = data['status'] as String? ?? 'idle';
      final battery = data['battery'] as int?;
      final updated = Map<String, MemberState>.from(state.members);
      if (updated.containsKey(userId)) {
        updated[userId] =
            updated[userId]!.copyWith(status: status, battery: battery);
        state = state.copyWith(members: updated);
      }
    });

    _sosSub = _socket.onSosAlert.listen((_) {
      state = state.copyWith(sosTriggered: true);
      Future.delayed(const Duration(seconds: 10), () {
        if (mounted) state = state.copyWith(sosTriggered: false);
      });
    });

    _snapshotSub = _socket.onSnapshot.listen((data) {
      final members = data['members'] as List<dynamic>? ?? [];
      final updated = Map<String, MemberState>.from(state.members);
      for (final m in members) {
        if (m is! Map<String, dynamic>) continue;
        final userId = m['user_id'] as String? ?? '';
        final nickname = m['nickname'] as String? ?? userId;
        if (userId.isEmpty) continue;
        final loc = m['lastLocation'] as Map<String, dynamic>?;
        final lat = (loc?['lat'] as num?)?.toDouble();
        final lng = (loc?['lng'] as num?)?.toDouble();
        final role = m['role'] as String? ?? 'member';
        final sharingEnabled = m['sharing_enabled'] as bool? ?? true;

        updated[userId] = MemberState(
          userId: userId,
          nickname: nickname,
          lat: lat ?? 0,
          lng: lng ?? 0,
          battery: loc?['battery'] as int?,
          status: loc?['status'] as String? ?? 'idle',
          role: role,
          sharingEnabled: sharingEnabled,
          updatedAt: DateTime.now(),
        );
      }
      state = state.copyWith(members: updated);

      final authUser = _ref.read(authProvider).valueOrNull;
      if (authUser != null && updated.containsKey(authUser.id)) {
        final me = updated[authUser.id]!;
        state = state.copyWith(
          myRole: me.role,
          sharingEnabled: me.sharingEnabled,
        );
        _gps.setSharingEnabled(me.sharingEnabled);
      }
      unawaited(_syncBlePresenceLifecycle());
    });
  }

  void _bindBleStreams() {
    state = state.copyWith(
      blePresenceStatus: _ble.status.state.name,
      blePresenceMessage: _ble.status.message,
    );

    _bleSightingSub = _ble.sightings.listen((sighting) {
      final updated = Map<String, BleMemberContact>.from(state.bleContacts)
        ..[sighting.userId] = BleMemberContact(
          userId: sighting.userId,
          rssi: sighting.rssi,
          seenAtMs: sighting.seenAtMs,
          deviceId: sighting.deviceId,
        );
      state = state.copyWith(bleContacts: updated);
    });

    _bleStatusSub = _ble.statuses.listen((status) {
      state = state.copyWith(
        blePresenceStatus: status.state.name,
        blePresenceMessage: status.message,
      );
    });
  }

  Future<void> _syncBlePresenceLifecycle() async {
    final authUser = _ref.read(authProvider).valueOrNull;
    final shouldRun = authUser != null &&
        state.isConnected &&
        state.gameState.status == 'in_progress' &&
        state.gameState.gameType == 'fantasy_wars_artifact';

    if (!shouldRun) {
      await _ble.stop();
      if (mounted && state.bleContacts.isNotEmpty) {
        state = state.copyWith(bleContacts: const {});
      }
      return;
    }

    await _ble.start(
      sessionId: _sessionId,
      userId: authUser.id,
      memberUserIds: state.members.keys,
    );
  }

  Future<void> _startGpsTracking() async {
    try {
      _gps.setSessionId(_sessionId);
      await _gps.startTracking();
      _myPositionSub = _gps.positionStream.listen((pos) {
        state = state.copyWith(myPosition: pos);

        final authUser = _ref.read(authProvider).valueOrNull;
        if (authUser != null) {
          final myId = authUser.id;
          final currentMe = state.members[myId];

          if (currentMe != null) {
            final updated = Map<String, MemberState>.from(state.members);
            updated[myId] = currentMe.copyWith(
              lat: pos.latitude,
              lng: pos.longitude,
              updatedAt: DateTime.now(),
            );
            state = state.copyWith(members: updated);
          }

          final distances = <String, double>{};
          String? closestId;
          double closestDist = double.infinity;
          for (final entry in state.members.entries) {
            if (entry.key == myId) continue;
            final member = entry.value;
            if (member.lat == 0 && member.lng == 0) continue;
            final dist = _haversineMeters(
              pos.latitude,
              pos.longitude,
              member.lat,
              member.lng,
            );
            distances[member.userId] = dist;
            if (dist < closestDist) {
              closestDist = dist;
              closestId = member.userId;
            }
          }
          state = state.copyWith(
            memberDistances: distances,
            proximateTargetId: closestDist <= 15.0 ? closestId : null,
          );
        }

        _checkGeofences(pos);
      });
    } catch (e) {
      debugPrint('[Map] GPS failed: $e');
    }
  }

  Future<void> _loadInitialMembers() async {
    try {
      final session =
          await _ref.read(sessionRepositoryProvider).getSession(_sessionId);
      final initialMembers = Map<String, MemberState>.from(state.members);
      for (final member in session.members) {
        if (!initialMembers.containsKey(member.userId)) {
          initialMembers[member.userId] = MemberState(
            userId: member.userId,
            nickname: member.nickname,
            lat: member.latitude ?? 0,
            lng: member.longitude ?? 0,
            battery: member.battery,
            status: member.status,
            role: member.role,
            sharingEnabled: member.sharingEnabled,
            updatedAt: DateTime.now(),
          );
        }
      }
      state = state.copyWith(members: initialMembers);

      final authUser = _ref.read(authProvider).valueOrNull;
      if (authUser != null) {
        final myList = session.members
            .where((member) => member.userId == authUser.id)
            .toList();
        if (myList.isNotEmpty) {
          final me = myList.first;
          state = state.copyWith(
            myRole: me.role,
            sharingEnabled: me.sharingEnabled,
          );
          _gps.setSharingEnabled(me.sharingEnabled);
        }
      }
    } catch (e) {
      debugPrint('[Map] Failed to load session members: $e');
    }

    unawaited(_syncBlePresenceLifecycle());
  }

  static double _haversineMeters(
      double lat1, double lng1, double lat2, double lng2) {
    const R = 6371000.0;
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLng = (lng2 - lng1) * math.pi / 180;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180) *
            math.cos(lat2 * math.pi / 180) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  void _checkGeofences(Position myPos) {
    if (_currentGeofences.isEmpty) return;

    for (final gf in _currentGeofences) {
      double distance = Geolocator.distanceBetween(
        myPos.latitude,
        myPos.longitude,
        gf.latitude,
        gf.longitude,
      );

      bool isCurrentlyInside = distance <= gf.radius;
      bool wasInside = _insideGeofences.contains(gf.id);

      if (isCurrentlyInside && !wasInside) {
        _insideGeofences.add(gf.id);
        debugPrint('[Geofence] 진입: ${gf.name}');
      } else if (!isCurrentlyInside && wasInside) {
        _insideGeofences.remove(gf.id);
        debugPrint('[Geofence] 이탈: ${gf.name}');
      }
    }
  }

  Future<void> toggleSharing(bool enabled) async {
    try {
      await _ref
          .read(sessionRepositoryProvider)
          .toggleSharing(_sessionId, enabled);
      _gps.setSharingEnabled(enabled);
      state = state.copyWith(sharingEnabled: enabled);

      if (enabled) {
        final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
        );
        state = state.copyWith(myPosition: pos);

        final authUser = _ref.read(authProvider).valueOrNull;
        if (authUser != null) {
          final myId = authUser.id;
          final currentMe = state.members[myId];

          if (currentMe != null) {
            final updated = Map<String, MemberState>.from(state.members);
            updated[myId] = currentMe.copyWith(
              lat: pos.latitude,
              lng: pos.longitude,
              status: 'moving',
              updatedAt: DateTime.now(),
            );
            state = state.copyWith(members: updated);
          }

          _socket.sendLocationUpdate(
              _sessionId, pos.latitude, pos.longitude, 'moving');
        }
      }
    } catch (e) {
      debugPrint('[Map] toggleSharing failed: $e');
    }
  }

  Future<void> toggleHideMember(String userId) async {
    final updated = Set<String>.from(state.hiddenMembers);
    if (updated.contains(userId)) {
      updated.remove(userId);
    } else {
      updated.add(userId);
    }
    state = state.copyWith(hiddenMembers: updated);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('hidden_$_sessionId', updated.toList());
  }

  void triggerSOS() {
    final pos = state.myPosition;
    _socket.sendSOS(lat: pos?.latitude, lng: pos?.longitude);
  }

  void sendKillAction(String targetUserId) {
    _socket.interactAction(
      sessionId: _sessionId,
      actionType: 'PROXIMITY_KILL',
      targetUserId: targetUserId,
    );
  }

  void startGame() {
    _socket.emitGameStart(_sessionId);
  }

  void openVote(Function(Map) onResult) {
    _socket.emitVoteOpen(_sessionId, onResult);
  }

  Future<void> reconnect() async {
    try {
      await _socket.connect();
      if (_socket.isConnected) {
        state = state.copyWith(isConnected: true, hasEverConnected: true);
        _socket.joinSession(_sessionId);
        unawaited(_syncBlePresenceLifecycle());
      }
    } catch (e) {
      debugPrint('[Map] Socket reconnect failed: $e');
    }
  }

  @override
  void dispose() {
    _joinRetryTimer?.cancel();
    _markerFlushTimer?.cancel();
    _locationSub?.cancel();
    _memberJoinSub?.cancel();
    _memberLeftSub?.cancel();
    _statusSub?.cancel();
    _sosSub?.cancel();
    _snapshotSub?.cancel();
    _connectionSub?.cancel();
    _myPositionSub?.cancel();
    _kickedSub?.cancel();
    _roleChangedSub?.cancel();
    _sessionExpiredSub?.cancel();
    _proximityKilledSub?.cancel();
    _playerEliminatedSub?.cancel();
    _gameStateSub?.cancel();
    _gameOverSub?.cancel();
    _bleSightingSub?.cancel();
    _bleStatusSub?.cancel();
    _gps.setSessionId(null);
    _gps.stopTracking();
    unawaited(_ble.stop());
    unawaited(_audio.leaveSession());
    _socket.disconnect();
    SharedPreferences.getInstance().then((p) => p.setBool('bg_active', false));
    FlutterBackgroundService().invoke('stopService');
    debugPrint('[Background] 포그라운드 서비스 종료 신호 발송');
    super.dispose();
  }
}

final mapSessionProvider = StateNotifierProvider.family
    .autoDispose<MapSessionNotifier, MapSessionState, String>(
  (ref, sessionId) => MapSessionNotifier(sessionId, ref),
);
