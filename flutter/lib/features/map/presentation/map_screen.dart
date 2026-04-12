// lib/features/map/presentation/map_screen.dart

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/socket_service.dart';
import '../../../core/services/location_service.dart';
import '../../../features/auth/data/auth_repository.dart';
import '../../../features/home/data/session_repository.dart';
import '../../../core/network/api_client.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import '../../geofence/data/geofence_repository.dart';
import '../../game/providers/game_provider.dart';
import '../../game/data/game_models.dart' as am_game;
import '../../game/presentation/game_meeting_screen.dart';
import '../../game/presentation/widgets/ai_chat_panel.dart';
import 'map_leaf_widgets.dart';
import 'map_overlay_widgets.dart';
import 'map_session_models.dart';

class MapSessionNotifier extends StateNotifier<MapSessionState> {
  MapSessionNotifier(this._sessionId, this._ref)
      : super(const MapSessionState(members: {})) {
    _init();
  }

  final String _sessionId;
  final Ref _ref;

  final _socket = SocketService();
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

  Timer? _joinRetryTimer;

  // 위치 업데이트 일괄 처리 (500ms 간격, 50m 이상 이동 시만 반영)
  final Map<String, MemberState> _pendingUpdates = {};
  Timer? _markerFlushTimer;

  // ★ 추가됨: 지오펜스 상태 관리를 위한 클래스 변수
  final Set<String> _insideGeofences = {}; // 현재 내가 들어가 있는 지오펜스 ID 목록
  List<dynamic> _currentGeofences =
      []; // 현재 세션의 지오펜스 목록 (dynamic은 실제 Geofence 모델로 변경 권장)

  Future<void> _init() async {
    // 1. 세션 이름: sessionListProvider 캐시에서 조회
    final cachedSessions = _ref.read(sessionListProvider).valueOrNull ?? [];
    final cached = cachedSessions.where((s) => s.id == _sessionId);

    if (cached.isNotEmpty) {
      state = state.copyWith(sessionName: cached.first.name);
    }

    // 숨김 멤버 로컬 저장소에서 복원
    final prefs = await SharedPreferences.getInstance();
    final hiddenList = prefs.getStringList('hidden_$_sessionId') ?? [];
    if (hiddenList.isNotEmpty) {
      state = state.copyWith(hiddenMembers: Set.from(hiddenList));
    }

    // ★ 추가됨: 현재 세션의 지오펜스 목록 로드
    // (이 부분은 실제 지오펜스 Provider나 Repository 호출 로직으로 수정하세요)
    try {
      _currentGeofences =
          await _ref.read(geofenceRepositoryProvider).getGeofences(_sessionId);
    } catch (e) {
      debugPrint('[Map] 지오펜스 로드 실패: $e');
    }

    _bindSocketStreams();

    // 3. 소켓 연결
    try {
      await _socket.connect();
      if (_socket.isConnected) {
        state = state.copyWith(isConnected: true, hasEverConnected: true);
        _socket.joinSession(_sessionId);
        _socket.requestGameState(_sessionId);
      }
    } catch (e) {
      debugPrint('[Map] Socket connect failed: $e');
    }

    _joinRetryTimer = Timer(const Duration(seconds: 30), () {
      if (mounted && state.members.isEmpty && state.isConnected) {
        _socket.joinSession(_sessionId);
      }
    });

    await _startGpsTracking();
    await _loadInitialMembers();

    // 6. 백그라운드 서비스용 데이터 저장 및 시작
    try {
      await prefs.setString('bg_session_id', _sessionId);
      await prefs.setString('bg_server_url', kApiBaseUrl);
      final token = await ApiClient().getAccessToken();
      if (token != null) {
        await prefs.setString('bg_token', token);
      }
      await prefs.setBool('bg_active', true);
      final bgService = FlutterBackgroundService();
      await bgService.startService();
      debugPrint('[Background] 포그라운드 서비스 시작됨');
    } catch (e) {
      debugPrint('[Background] 서비스 시작 실패: $e');
    }
  }

  // ── 소켓 구독 바인딩 ─────────────────────────────────────────────────────
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
    });

    _gameOverSub = _socket.onGameOver.listen((data) {
      state = state.copyWith(
        gameState: GameState(
          status: 'finished',
          winnerId: data['winnerId'] as String?,
        ),
      );
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
      if (connected) {
        _socket.joinSession(_sessionId);
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
        if (dist < 50) return;
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
    });

    _memberLeftSub = _socket.onMemberLeft.listen((data) {
      final userId = data['userId'] as String? ?? '';
      final updated = Map<String, MemberState>.from(state.members)
        ..remove(userId);
      state = state.copyWith(members: updated);
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
    });
  }

  Future<void> _startGpsTracking() async {
    try {
      await _gps.startTracking();
      _gps.setSessionId(_sessionId);
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
  }

  // ── 근접 거리 계산 (Haversine, 미터) ────────────────────────────────────
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

  // ★ 추가됨: 지오펜스 진입/이탈 판정 및 알림 호출 함수
  void _checkGeofences(Position myPos) {
    if (_currentGeofences.isEmpty) return;

    for (final gf in _currentGeofences) {
      // gf 객체의 속성 이름(lat, lng, radius, id, name)은 실제 모델에 맞게 변경하세요.
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
        // NotificationService().showNotification('지오펜스 진입', '${gf.name} 영역에 들어왔습니다!');
        debugPrint('[Geofence] 진입: ${gf.name}');
      } else if (!isCurrentlyInside && wasInside) {
        _insideGeofences.remove(gf.id);
        // NotificationService().showNotification('지오펜스 이탈', '${gf.name} 영역을 벗어났습니다.');
        debugPrint('[Geofence] 이탈: ${gf.name}');
      }
    }
  }

  // ── 위치 공유 ON/OFF 토글 (즉각 갱신 로직 포함) ────────────────────────────────
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

  // ── 멤버 숨김 토글 ──────────────────────────────────────────────────────
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
    _gps.setSessionId(null);
    _gps.stopTracking();
    _socket.disconnect();
    // 방에서 나가거나 강퇴당하면 백그라운드 서비스를 종료합니다.
    SharedPreferences.getInstance().then((p) => p.setBool('bg_active', false));
    FlutterBackgroundService().invoke('stopService');
    debugPrint('[Background] 포그라운드 서비스 종료 신호 발송');
    super.dispose();
  }
}

// Provider: sessionId 파라미터를 받기 위해 family 사용
final mapSessionProvider = StateNotifierProvider.family
    .autoDispose<MapSessionNotifier, MapSessionState, String>(
  (ref, sessionId) => MapSessionNotifier(sessionId, ref),
);

// ─────────────────────────────────────────────────────────────────────────────
// MapScreen
// ─────────────────────────────────────────────────────────────────────────────

class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  NaverMapController? _mapController;
  bool _followMe = true;

  // ── 마커 캐시 ─────────────────────────────────────────────────────────────
  // members/sharingEnabled/hiddenMembers가 실제로 변경됐을 때만 마커를 재계산한다.
  // myPosition이 바뀌는 경우(GPS 업데이트)에는 재계산하지 않는다.
  Set<NMarker> _cachedMarkers = {};
  Map<String, MemberState>? _prevMembers;
  bool? _prevSharingEnabled;
  Set<String>? _prevHiddenMembers;
  String? _prevMyUserId;
  Set<String>? _prevEliminatedUserIds;

  @override
  Widget build(BuildContext context) {
    // 강제 퇴장 감지 → 홈으로 이동
    ref.listen<MapSessionState>(
      mapSessionProvider(widget.sessionId),
      (prev, next) {
        if (next.wasKicked) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              context.go(AppRoutes.home);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('세션에서 강제 퇴장 처리되었습니다.'),
                  backgroundColor: Colors.red,
                ),
              );
            }
          });
        }
      },
    );

    // 게임 종료 감지 → 결과 화면으로 이동
    ref.listen<am_game.AmongUsGameState>(
      gameProvider(widget.sessionId),
      (prev, next) {
        if (prev?.shouldNavigateToRole != true && next.shouldNavigateToRole) {
          context.push('/game/${widget.sessionId}/role');
          ref
              .read(gameProvider(widget.sessionId).notifier)
              .resetRoleNavigation();
        }

        if (prev?.gameOverWinner == null && next.gameOverWinner != null) {
          context.go('/game/${widget.sessionId}/result/${next.gameOverWinner}');
        }
      },
    );

    final mapState = ref.watch(mapSessionProvider(widget.sessionId));
    final authUser = ref.watch(authProvider).valueOrNull;
    final amgState = ref.watch(gameProvider(widget.sessionId));
    final completed =
        (amgState.missionProgress['completed'] as num?)?.toInt() ?? 0;
    final total = (amgState.missionProgress['total'] as num?)?.toInt() ?? 0;
    final rawPercent =
        (amgState.missionProgress['percent'] as num?)?.toDouble() ??
            (total > 0 ? completed / total : 0);
    final percentLabel = ((((rawPercent > 1 ? rawPercent / 100 : rawPercent)
                    .clamp(0.0, 1.0) as num)
                .toDouble()) *
            100)
        .round();

    // 활성 모듈 목록 (세션 캐시에서 조회)
    final activeModules = getSessionModules(ref).toSet();
    final isDefaultMode = activeModules.isEmpty;
    const aiChatHeight = 236.0;
    final showAiChat = amgState.isStarted && !isDefaultMode;
    final showMemberPanel = isDefaultMode;
    final overlayBottomOffset = showAiChat ? aiChatHeight + 20 : 290.0;
    final floatingControlsBottom =
        showAiChat ? aiChatHeight + 104 : (showMemberPanel ? 280.0 : 96.0);

    // 내 위치 따라가기
    final myPos = mapState.myPosition;
    if (_followMe && myPos != null && _mapController != null) {
      _mapController!.updateCamera(NCameraUpdate.scrollAndZoomTo(
        target: NLatLng(myPos.latitude, myPos.longitude),
      )..setAnimation(animation: NCameraAnimation.easing));
    }

    // 마커 캐시: 마커에 영향 주는 상태가 실제로 바뀐 경우에만 재계산
    final myUserId = authUser?.id;
    if (!identical(_prevMembers, mapState.members) ||
        _prevSharingEnabled != mapState.sharingEnabled ||
        !identical(_prevHiddenMembers, mapState.hiddenMembers) ||
        !identical(_prevEliminatedUserIds, mapState.eliminatedUserIds) ||
        _prevMyUserId != myUserId) {
      _prevMembers = mapState.members;
      _prevSharingEnabled = mapState.sharingEnabled;
      _prevHiddenMembers = mapState.hiddenMembers;
      _prevEliminatedUserIds = mapState.eliminatedUserIds;
      _prevMyUserId = myUserId;

      _cachedMarkers = _buildMarkers(
        mapState.members,
        myUserId,
        mapState.sharingEnabled,
        mapState.hiddenMembers,
        mapState.eliminatedUserIds,
      );

      // 네이버 지도는 오버레이를 컨트롤러를 통해 직접 갱신해야 합니다.
      if (_mapController != null) {
        _mapController!.clearOverlays();
        _mapController!.addOverlayAll(_cachedMarkers);
      }
    }

    return Scaffold(
      body: Stack(
        children: [
          // ── Naver Map ───────────────────────────────────────────────────
          NaverMap(
            options: NaverMapViewOptions(
              initialCameraPosition: NCameraPosition(
                target: myPos != null
                    ? NLatLng(myPos.latitude, myPos.longitude)
                    : const NLatLng(37.5665, 126.9780),
                zoom: 14.0,
              ),
              locationButtonEnable: false,
              zoomGesturesEnable: true,
            ),
            onMapReady: (controller) {
              _mapController = controller;
              if (_cachedMarkers.isNotEmpty) {
                _mapController!.addOverlayAll(_cachedMarkers);
              }
            },
            onCameraChange: (reason, animated) {
              if (reason == NCameraUpdateReason.gesture) {
                setState(() => _followMe = false);
              }
            },
          ),

          // ── 상단 앱바 ─────────────────────────────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _TopBar(
              sessionId: widget.sessionId,
              sessionName: mapState.sessionName ?? '세션',
              isConnected: mapState.isConnected,
              hasEverConnected: mapState.hasEverConnected,
              memberCount: mapState.members.length,
              sharingEnabled: mapState.sharingEnabled,
              myRole: mapState.myRole,
              onSharingToggle: (enabled) => ref
                  .read(mapSessionProvider(widget.sessionId).notifier)
                  .toggleSharing(enabled),
              onReconnect: () => ref
                  .read(mapSessionProvider(widget.sessionId).notifier)
                  .reconnect(),
            ),
          ),

          // ── 오른쪽 FAB들 ──────────────────────────────────────────────────
          MapFloatingControls(
            followMe: _followMe,
            bottomOffset: floatingControlsBottom,
            onFollowPressed: () {
              setState(() => _followMe = true);
              if (myPos != null) {
                _mapController?.updateCamera(
                  NCameraUpdate.scrollAndZoomTo(
                    target: NLatLng(myPos.latitude, myPos.longitude),
                  )..setAnimation(animation: NCameraAnimation.easing),
                );
              }
            },
            onFitPressed: () => _fitAllMembers(mapState.members, myPos),
          ),

          // ── SOS 경고 배너 ─────────────────────────────────────────────────
          MapOverlayLayer(
            mapState: mapState,
            amongUsState: amgState,
            activeModules: activeModules,
            authUserId: authUser?.id,
            onKillAction: () => ref
                .read(mapSessionProvider(widget.sessionId).notifier)
                .sendKillAction(mapState.proximateTargetId!),
            onOpenVote: () => ref
                .read(mapSessionProvider(widget.sessionId).notifier)
                .openVote((result) {
              if (result['ok'] == true) return;

              final error = result['error']?.toString() ?? '투표를 시작하지 못했습니다.';
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(error)),
              );
            }),
            onCloseFinished: () => context.pop(),
            bottomActionOffset: overlayBottomOffset,
            showTopStatus: isDefaultMode,
          ),

          if (amgState.isStarted && !isDefaultMode)
            Positioned(
              top: MediaQuery.of(context).padding.top + 86,
              left: 16,
              right: 16,
              child: _GameInfoStrip(
                role: amgState.myRole,
                aliveCount: mapState.gameState.aliveCount,
                roundNumber: activeModules.contains('round')
                    ? mapState.gameState.roundNumber
                    : null,
                missionText: activeModules.contains('mission')
                    ? '미션 $completed / $total ($percentLabel%)'
                    : null,
              ),
            ),
          /* if (amgState.isStarted)
            Positioned(
              top: 96,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  width: MediaQuery.sizeOf(context).width * 0.6,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '미션 진행도 $completed / $total ($percentLabel%)',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: progressValue,
                          minHeight: 8,
                          backgroundColor: Colors.white24,
                          valueColor:
                              const AlwaysStoppedAnimation<Color>(Colors.green),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ), */

          if (mapState.myRole == 'host' &&
              mapState.gameState.status == 'none' &&
              !amgState.isStarted)
            Positioned(
              right: 16,
              bottom: 120,
              child: FloatingActionButton.extended(
                heroTag: 'start_game',
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
                onPressed: () => ref
                    .read(gameProvider(widget.sessionId).notifier)
                    .startGame(),
                icon: const Icon(Icons.play_arrow),
                label: const Text(
                  '게임 시작',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),

          if (showAiChat)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: AIChatPanel(
                sessionId: widget.sessionId,
                height: aiChatHeight,
              ),
            ),

          // ── 회의 화면 오버레이 ──────────────────────────────────────────
          if (amgState.meetingPhase != 'none')
            Positioned.fill(
              child: GameMeetingScreen(
                sessionId: widget.sessionId,
                memberNames: {
                  for (final e in mapState.members.entries)
                    e.key: e.value.nickname,
                },
                myUserId: authUser?.id ?? '',
              ),
            ),

          // ── 하단 멤버 패널 ─────────────────────────────────────────────────
          if (showMemberPanel)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: MapBottomMemberPanel(
                members: mapState.members.values.toList(),
                myPosition: myPos,
                hiddenMembers: mapState.hiddenMembers,
                eliminatedUserIds: mapState.eliminatedUserIds,
                onSOS: () => _confirmSOS(context, ref),
                onMemberTap: (member) {
                  if (member.lat == 0 && member.lng == 0) return;
                  setState(() => _followMe = false);
                  _mapController?.updateCamera(
                    NCameraUpdate.scrollAndZoomTo(
                      target: NLatLng(member.lat, member.lng),
                      zoom: 15,
                    )..setAnimation(animation: NCameraAnimation.easing),
                  );
                },
                onHideToggle: (userId) => ref
                    .read(mapSessionProvider(widget.sessionId).notifier)
                    .toggleHideMember(userId),
              ),
            ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────────
// (MapScreen 클래스 내부 교체할 코드 영역)
// ─────────────────────────────────────────────────────────────────────────────

  Set<NMarker> _buildMarkers(
    Map<String, MemberState> members,
    String? myUserId,
    bool sharingEnabled,
    Set<String> hiddenMembers,
    Set<String> eliminatedUserIds,
  ) {
    final markers = <NMarker>{};
    for (final m in members.values) {
      if (m.lat == 0 && m.lng == 0) continue;

      final isMe = m.userId == myUserId;
      final isEliminated = eliminatedUserIds.contains(m.userId);
      if (isMe && !sharingEnabled) continue;
      if (hiddenMembers.contains(m.userId)) continue;

      // 탈락자는 해골 이모지 접두 + 회색 핀
      final nameCaption = isEliminated
          ? '💀 ${m.nickname}'
          : (isMe ? '${m.nickname} (나)' : m.nickname);
      final pinColor = isEliminated
          ? Colors.grey
          : (isMe ? const Color(0xFF2196F3) : Colors.redAccent);
      final captionColor = isEliminated
          ? Colors.grey
          : (isMe ? const Color(0xFF2196F3) : Colors.black87);

      final marker = NMarker(
        id: m.userId,
        position: NLatLng(m.lat, m.lng),
      )
        ..setIconTintColor(pinColor)
        ..setCaption(
          NOverlayCaption(
            text: nameCaption,
            textSize: 14,
            color: captionColor,
            haloColor: Colors.white,
          ),
        )
        ..setSubCaption(
          NOverlayCaption(
            text: isEliminated ? '탈락' : _markerSnippet(m),
            textSize: 12,
            color: isEliminated ? Colors.grey : Colors.grey[700]!,
            haloColor: Colors.white,
          ),
        );

      markers.add(marker);
    }
    return markers;
  }

  String _markerSnippet(MemberState m) {
    final parts = <String>[];
    if (m.status == 'moving') {
      parts.add('이동중');
    } else {
      parts.add('정지');
    }
    if (m.battery != null) parts.add('배터리(${m.battery}%)');
    return parts.join(' '); // "이동중 배터리(80%)" 형태로 출력
  }

  List<String> getSessionModules(WidgetRef ref) {
    final sessions = ref.watch(sessionListProvider).valueOrNull ?? [];
    final match = sessions.where((s) => s.id == widget.sessionId);
    return match.isNotEmpty ? match.first.activeModules : const [];
  }

  void _fitAllMembers(Map<String, MemberState> members, Position? myPos) {
    if (_mapController == null) return;
    setState(() => _followMe = false);

    final points = <NLatLng>[
      if (myPos != null) NLatLng(myPos.latitude, myPos.longitude),
      ...members.values
          .where((m) => m.lat != 0 || m.lng != 0)
          .map((m) => NLatLng(m.lat, m.lng)),
    ];

    if (points.isEmpty) return;
    if (points.length == 1) {
      _mapController!.updateCamera(
        NCameraUpdate.scrollAndZoomTo(
          target: points.first,
          zoom: 15,
        )..setAnimation(animation: NCameraAnimation.easing),
      );
      return;
    }

    var minLat = points.first.latitude;
    var maxLat = points.first.latitude;
    var minLng = points.first.longitude;
    var maxLng = points.first.longitude;

    for (final p in points) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLng = math.min(minLng, p.longitude);
      maxLng = math.max(maxLng, p.longitude);
    }

    final bounds = NLatLngBounds(
      southWest: NLatLng(minLat, minLng),
      northEast: NLatLng(maxLat, maxLng),
    );

    _mapController!.updateCamera(
      NCameraUpdate.fitBounds(bounds, padding: const EdgeInsets.all(80))
        ..setAnimation(animation: NCameraAnimation.easing),
    );
  }

  void _confirmSOS(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber, color: Colors.red),
            SizedBox(width: 8),
            Text('SOS 발송'),
          ],
        ),
        content: const Text('모든 세션 멤버에게 긴급 알림을 보내시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              ref
                  .read(mapSessionProvider(widget.sessionId).notifier)
                  .triggerSOS();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('SOS 알림을 전송했습니다'),
                  backgroundColor: Colors.red,
                ),
              );
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: const Text('전송'),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 상단 바
// ─────────────────────────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.sessionId,
    required this.sessionName,
    required this.isConnected,
    required this.hasEverConnected,
    required this.memberCount,
    required this.sharingEnabled,
    required this.myRole,
    required this.onSharingToggle,
    this.onReconnect,
  });

  final String sessionId;
  final String sessionName;
  final bool isConnected;
  final bool hasEverConnected;
  final int memberCount;
  final bool sharingEnabled;
  final String myRole;
  final ValueChanged<bool> onSharingToggle;
  final VoidCallback? onReconnect;

  Color _statusColor() {
    if (isConnected) return Colors.green;
    if (hasEverConnected) return Colors.red;
    return Colors.orange;
  }

  String _statusText() {
    if (isConnected) return '연결됨';
    if (hasEverConnected) return '재연결 중...';
    return '연결 중...';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 8,
        left: 16,
        right: 16,
        bottom: 12,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          // 뒤로가기
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(),
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 8),

          // 세션 이름 + 멤버 수
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  sessionName,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '$memberCount명 참여 중',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ],
            ),
          ),

          // 연결 상태 표시 (연결 끊김 시 탭으로 수동 재연결)
          GestureDetector(
            onTap: !isConnected ? onReconnect : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _statusColor().withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _statusColor(),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _statusText(),
                    style: TextStyle(
                      fontSize: 12,
                      color: _statusColor(),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 위치 공유 토글
          IconButton(
            icon: Icon(
              sharingEnabled ? Icons.location_on : Icons.location_off,
              color: sharingEnabled ? const Color(0xFF2196F3) : Colors.grey,
            ),
            tooltip: sharingEnabled ? '위치 공유 중' : '위치 공유 꺼짐',
            onPressed: () => onSharingToggle(!sharingEnabled),
            visualDensity: VisualDensity.compact,
          ),
          // 더보기 메뉴
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              switch (value) {
                case 'history':
                  context.push(
                      AppRoutes.history.replaceFirst(':sessionId', sessionId));
                case 'geofence':
                  context.push(
                      AppRoutes.geofence.replaceFirst(':sessionId', sessionId));
                case 'members':
                  context.push('/session/$sessionId/members');
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'history',
                child: Row(
                  children: [
                    Icon(Icons.history, size: 20),
                    SizedBox(width: 12),
                    Text('위치 기록'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'geofence',
                child: Row(
                  children: [
                    Icon(Icons.radio_button_checked, size: 20),
                    SizedBox(width: 12),
                    Text('지오펜스'),
                  ],
                ),
              ),
              if (myRole == 'host' || myRole == 'admin')
                const PopupMenuItem(
                  value: 'members',
                  child: Row(
                    children: [
                      Icon(Icons.manage_accounts, size: 20),
                      SizedBox(width: 12),
                      Text('멤버 관리'),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GameInfoStrip extends StatelessWidget {
  const _GameInfoStrip({
    this.role,
    required this.aliveCount,
    this.roundNumber,
    this.missionText,
  });

  final am_game.GameRole? role;
  final int aliveCount;
  final int? roundNumber;
  final String? missionText;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: true,
      child: Align(
        alignment: Alignment.topCenter,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 420),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.54),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              if (role != null)
                _GameInfoChip(
                  label: role!.isImpostor ? '임포스터' : '크루원',
                  color: role!.isImpostor
                      ? const Color(0xFFF87171)
                      : const Color(0xFF4ADE80),
                ),
              _GameInfoChip(
                label: '생존 $aliveCount명',
                color: Colors.white,
              ),
              if (roundNumber != null)
                _GameInfoChip(
                  label: '라운드 $roundNumber',
                  color: const Color(0xFFC4B5FD),
                ),
              if (missionText != null && missionText!.isNotEmpty)
                _GameInfoChip(
                  label: missionText!,
                  color: const Color(0xFF86EFAC),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GameInfoChip extends StatelessWidget {
  const _GameInfoChip({
    required this.label,
    required this.color,
  });

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 하단 멤버 패널
// ─────────────────────────────────────────────────────────────────────────────
