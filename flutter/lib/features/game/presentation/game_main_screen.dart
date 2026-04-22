// lib/features/game/presentation/game_main_screen.dart
//
// 단일 진입점 게임 메인 화면
// - 배경: NaverMap (지도 위에 마커/플레이영역 폴리곤)
// - 오버레이: 반투명 상단 헤더 + 텍스트 기반 플로팅 버튼들
// - 접이식 패널: AI 채팅, 멤버 목록, 미션 목록 등은 바텀시트로
// - 아이콘/이모지 금지: 오직 텍스트로만 UI 구성
//
// 이 위젯의 책임은 "레이아웃 조립"이다. 지도 오버레이 수명주기는
// [MapOverlayCoordinator]가, 독립 오버레이 UI는 widgets/ 하위 파일이,
// ref.listen 반응은 `_handleGameStateChanged` / `_handleMapStateChanged`가
// 담당한다.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/app_initialization_service.dart';
import '../../../core/services/mediasoup_audio_service.dart';
import '../../../core/services/socket_service.dart';
import '../../auth/data/auth_repository.dart';
import '../../home/data/session_repository.dart';
import '../../map/data/map_session_provider.dart';
import '../../map/presentation/map_session_models.dart';
import '../data/game_models.dart';
import '../providers/game_provider.dart';
import 'game_meeting_screen.dart';
import 'minigames/minigame_wrapper_screen.dart';
import 'qr_scanner_screen.dart';
import 'game_mode_plugin.dart';
import 'widgets/game_main_map_overlay_coordinator.dart';
import 'widgets/game_main_overlays.dart';
import 'widgets/game_main_shell_widgets.dart';
import 'widgets/mission_list_sheet.dart';

class GameMainScreen extends ConsumerStatefulWidget {
  const GameMainScreen({
    super.key,
    required this.sessionId,
    required this.sessionType,
  });

  final String sessionId;
  final SessionType sessionType;

  @override
  ConsumerState<GameMainScreen> createState() => _GameMainScreenState();
}

class _GameMainScreenState extends ConsumerState<GameMainScreen>
    with WidgetsBindingObserver {
  // ── 지도 컨트롤러 및 상태 ───────────────────────────────────────────────
  NaverMapController? _mapController;
  bool _mapSdkReady = false;
  bool _followMe = true;

  // 오버레이(폴리곤/유저 마커/미션 마커) 수명주기 관리
  late final MapOverlayCoordinator _overlayCoordinator;

  // ── 모드 플러그인 ─────────────────────────────────────────────────
  late final GameModePlugin _modePlugin;

  // ── AI 채팅 패널 ─────────────────────────────────────────────────
  bool _aiChatExpanded = false;
  static const double _kChatHandleH = 48.0;
  static const double _kChatContentH = 320.0;

  // ── 세션 정보 오버레이 ───────────────────────────────────────────────
  bool _showSessionInfo = false;
  void _openSessionInfo() => setState(() => _showSessionInfo = true);
  void _closeSessionInfo() => setState(() => _showSessionInfo = false);

  // ── 구역 이탈 경고 ──────────────────────────────────────────────────
  // 이탈 판정은 GameNotifier가 수행하며, 본 화면은 state.isOutOfBounds를 읽어
  // 펄스 애니메이션만 로컬에서 관리합니다.
  bool _boundsAlertPulse = false;
  Timer? _boundsAlertTimer;

  void _startBoundsPulse() {
    _boundsAlertTimer?.cancel();
    _boundsAlertTimer =
        Timer.periodic(const Duration(milliseconds: 700), (_) {
      if (!mounted) {
        _boundsAlertTimer?.cancel();
        return;
      }
      setState(() => _boundsAlertPulse = !_boundsAlertPulse);
    });
  }

  void _stopBoundsPulse() {
    _boundsAlertTimer?.cancel();
    _boundsAlertTimer = null;
    if (_boundsAlertPulse) setState(() => _boundsAlertPulse = false);
  }

  // ── KILL 쿨타임 ─────────────────────────────────────────────────────
  static const int _kKillCooldownDefault = 30;
  int _killCooldownSecs = 0;
  int _killCooldownDuration = _kKillCooldownDefault;
  Timer? _killCooldownTimer;

  void _handleKill(String targetId) {
    if (_killCooldownSecs > 0) return;
    ref.read(gameProvider(widget.sessionId).notifier).sendKill(targetId);
    _startKillCooldown();
  }

  void _startKillCooldown() {
    setState(() => _killCooldownSecs = _killCooldownDuration);
    _killCooldownTimer?.cancel();
    _killCooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _killCooldownSecs--;
        if (_killCooldownSecs <= 0) {
          _killCooldownSecs = 0;
          timer.cancel();
          _killCooldownTimer = null;
        }
      });
    });
  }

  // ── 역할 화면 중복 진입 방지 가드 ──────────────────────────────────
  // 한 번 true가 되면 절대 false로 되돌리지 않음 → 소켓 재연결/재빌드 시 중복 push 방지
  bool _roleNavDone = false;

  // ── 게임 보이스 채널 상태 ──────────────────────────────────────────
  // 기본값: 미연결. 사용자가 "게임 보이스 채널 연결" 버튼을 눌러야 연결됨.
  bool _gameVoiceConnected = false;
  bool _gameVoiceConnecting = false;

  // ── Lifecycle ───────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _modePlugin = createPlugin(widget.sessionType);
    _overlayCoordinator = MapOverlayCoordinator(
      controllerGetter: () => _mapController,
      isAlive: () => mounted,
      readGameState: () => ref.read(gameProvider(widget.sessionId)),
    );
    WidgetsBinding.instance.addObserver(this);
    unawaited(_ensureMapSdkReady());
    unawaited(_loadSessionConfig());
    // 게임 화면 진입 시 로비 보이스 연결을 끊는다.
    // 사용자가 명시적으로 "게임 보이스 채널 연결"을 눌러야 재연결.
    unawaited(MediaSoupAudioService().leaveSession());
  }

  Future<void> _connectGameVoice() async {
    if (_gameVoiceConnecting || _gameVoiceConnected) return;
    setState(() => _gameVoiceConnecting = true);
    try {
      await MediaSoupAudioService().ensureJoined(
        widget.sessionId,
        publishMic: true,
        channelId: 'game',
      );
      if (!mounted) return;
      setState(() {
        _gameVoiceConnected = true;
        _gameVoiceConnecting = false;
      });
    } catch (e) {
      debugPrint('[GameMain] game voice connect failed: $e');
      if (!mounted) return;
      setState(() => _gameVoiceConnecting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('게임 보이스 연결 실패: $e')),
      );
    }
  }

  Future<void> _disconnectGameVoice() async {
    await MediaSoupAudioService().leaveSession();
    if (!mounted) return;
    setState(() => _gameVoiceConnected = false);
  }

  /// 서버에서 세션을 직접 조회해 플레이 영역 및 쿨타임을 초기화합니다.
  /// 플레이 영역은 GameProvider에 반영되고, ref.listen이 폴리곤 렌더링과
  /// bounds check 시작을 자동으로 트리거합니다.
  Future<void> _loadSessionConfig() async {
    try {
      final session = await ref
          .read(sessionRepositoryProvider)
          .getSession(widget.sessionId);
      if (!mounted) return;
      setState(() => _killCooldownDuration = session.killCooldown);
      final area = session.playableArea;
      if (area != null && area.length >= 3) {
        ref
            .read(gameProvider(widget.sessionId).notifier)
            .setPlayableArea(area);
      }
    } catch (e) {
      debugPrint('[GameMain] 세션 설정 로드 실패: $e');
      _killCooldownDuration = _kKillCooldownDefault;
    }
  }

  /// '내 위치' 버튼 핸들러.
  /// 1) 위치 권한 확인/요청
  /// 2) 권한 OK → 지도 tracking mode를 follow로 (현 위치 센터 + 추적)
  /// 3) myPosition이 아직 없으면 Geolocator로 즉시 현재 좌표를 얻어 카메라 이동
  Future<void> _onMyLocationPressed() async {
    final granted = await _ensureLocationPermission();
    if (!granted) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('위치 권한이 필요합니다. 설정에서 허용해 주세요.')),
      );
      return;
    }

    if (!mounted) return;
    setState(() => _followMe = true);

    final controller = _mapController;
    if (controller == null) return;

    try {
      controller.setLocationTrackingMode(NLocationTrackingMode.follow);
    } catch (e) {
      debugPrint('[GameMain] setLocationTrackingMode 실패: $e');
    }

    // 이미 알고 있는 좌표가 있으면 즉시 카메라만 이동해 UX 끊김 방지.
    final known = ref.read(mapSessionProvider(widget.sessionId)).myPosition;
    if (known != null) {
      await controller.updateCamera(
        NCameraUpdate.withParams(
          target: NLatLng(known.latitude, known.longitude),
          zoom: 17,
        )..setAnimation(animation: NCameraAnimation.easing),
      );
      return;
    }

    // 아직 GPS fix가 없다면 직접 한 번 가져와 카메라 이동.
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 5),
      );
      if (!mounted || _mapController != controller) return;
      await controller.updateCamera(
        NCameraUpdate.withParams(
          target: NLatLng(position.latitude, position.longitude),
          zoom: 17,
        )..setAnimation(animation: NCameraAnimation.easing),
      );
    } catch (e) {
      debugPrint('[GameMain] getCurrentPosition 실패: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('현재 위치를 가져올 수 없습니다.')),
      );
    }
  }

  Future<bool> _ensureLocationPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return false;
    }
    return true;
  }

  Future<void> _ensureMapSdkReady() async {
    try {
      await AppInitializationService().ensureNaverMapInitialized();
      if (!mounted) return;
      setState(() => _mapSdkReady = true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('지도 초기화 실패: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  void dispose() {
    _modePlugin.dispose();
    _killCooldownTimer?.cancel();
    _boundsAlertTimer?.cancel();
    _overlayCoordinator.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _onAppBackgrounded();
    } else if (state == AppLifecycleState.resumed) {
      _onAppForegrounded();
    }
  }

  // 앱이 백그라운드로 내려갈 때 백그라운드 GPS 서비스를 시작한다.
  // startService()는 새 Flutter 엔진을 띄워 무거우므로, 포그라운드에서는 절대 호출하지 않는다.
  Future<void> _onAppBackgrounded() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('bg_active', false);
      final service = FlutterBackgroundService();
      if (!await service.isRunning()) {
        await service.startService();
      }
    } catch (e) {
      debugPrint('[App] 백그라운드 서비스 시작 실패: $e');
    }
  }

  void _onAppForegrounded() {
    // 포그라운드 복귀 시: bg_active 플래그 복구, 백그라운드 서비스 중지, 소켓 동기화
    SharedPreferences.getInstance().then((prefs) => prefs.setBool('bg_active', true));
    FlutterBackgroundService().invoke('stopService');
    debugPrint('[App] 포그라운드 복귀 → 소켓 상태 즉시 동기화 시작');
    SocketService().requestGameState(widget.sessionId);
    SocketService().emit(
      SocketEvents.joinSession,
      {'sessionId': widget.sessionId},
    );
  }

  // ── 세션 모듈 조회 ──────────────────────────────────────────────────
  // sessionListProvider가 비어있을 경우 sessionType.toModules()로 폴백
  Set<String> _getActiveModules() {
    final sessions = ref.read(sessionListProvider).valueOrNull ?? const [];
    final match = sessions.where((s) => s.id == widget.sessionId);
    if (match.isNotEmpty) return match.first.activeModules.toSet();
    // 폴백: 세션 타입에서 모듈 목록 추론
    return widget.sessionType.toModules().toSet();
  }

  // ── 나가기 ─────────────────────────────────────────────────────────
  Future<void> _confirmLeaveGame() async {
    final shouldLeave = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('게임 나가기'),
            content: const Text('지금 나가면 게임 연결과 위치 공유가 종료됩니다. 정말로 나가시겠습니까?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('취소'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
                child: const Text('나가기'),
              ),
            ],
          ),
        ) ??
        false;

    if (!shouldLeave || !mounted) return;
    await _leaveGame();
  }

  Future<void> _leaveGame() async {
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    try {
      await ref.read(sessionRepositoryProvider).leaveSession(widget.sessionId);
      SocketService().leaveSession(sessionId: widget.sessionId);
      await MediaSoupAudioService().leaveSession();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('bg_active', false);
      FlutterBackgroundService().invoke('stopService');
      if (!mounted) return;
      router.go(AppRoutes.home);
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('게임 나가기 실패: $e'), backgroundColor: Colors.red),
      );
    }
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
        NCameraUpdate.scrollAndZoomTo(target: points.first, zoom: 15)
          ..setAnimation(animation: NCameraAnimation.easing),
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

  // ── 바텀시트: 멤버 목록 / 미션 / 사보타지 / 시체 신고 ─────────────────

  void _openMemberSheet(MapSessionState mapState, String? myUserId) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) {
        final members = mapState.members.values.toList();
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('참여자 (${members.length})',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                if (members.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text('참여자가 없습니다.',
                        style: TextStyle(color: Colors.white54)),
                  )
                else
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height * 0.5,
                    ),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: members.length,
                      separatorBuilder: (_, __) =>
                          const Divider(color: Colors.white12, height: 1),
                      itemBuilder: (ctx, i) {
                        final m = members[i];
                        final isMe = m.userId == myUserId;
                        final isEliminated =
                            mapState.eliminatedUserIds.contains(m.userId);
                        final dist = mapState.memberDistances[m.userId];
                        final distLabel = dist != null
                            ? (dist < 1000
                                ? '${dist.toStringAsFixed(0)}m'
                                : '${(dist / 1000).toStringAsFixed(1)}km')
                            : '-';
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            isMe ? '${m.nickname} (나)' : m.nickname,
                            style: TextStyle(
                              color: isEliminated
                                  ? Colors.grey
                                  : Colors.white,
                              fontWeight: FontWeight.w600,
                              decoration: isEliminated
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                          ),
                          subtitle: Text(
                            isEliminated ? '탈락' : '거리 $distLabel',
                            style: TextStyle(
                                color: isEliminated
                                    ? Colors.redAccent
                                    : Colors.white54,
                                fontSize: 12),
                          ),
                          trailing: isMe
                              ? null
                              : TextButton(
                                  onPressed: () {
                                    if (m.lat == 0 && m.lng == 0) return;
                                    Navigator.pop(ctx);
                                    setState(() => _followMe = false);
                                    _mapController?.updateCamera(
                                      NCameraUpdate.scrollAndZoomTo(
                                        target: NLatLng(m.lat, m.lng),
                                        zoom: 15,
                                      )..setAnimation(
                                          animation: NCameraAnimation.easing),
                                    );
                                  },
                                  child: const Text('지도에서 보기',
                                      style: TextStyle(color: Colors.cyan)),
                                ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openSabotageSheet(List<Mission> missions) {
    final targets = missions
        .where((m) =>
            m.type.isMapBased &&
            m.status != MissionStatus.completed &&
            !m.isSabotaged)
        .toList();

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1a1a2e),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('사보타지할 미션 선택',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              if (targets.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('사보타지할 수 있는 미션이 없습니다.',
                      style: TextStyle(color: Colors.white54)),
                )
              else
                ...targets.map((m) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(m.title,
                          style: const TextStyle(color: Colors.white)),
                      trailing: TextButton(
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          SocketService()
                              .sendTriggerSabotage(widget.sessionId, m.id);
                        },
                        style: TextButton.styleFrom(
                          backgroundColor: Colors.red.shade800,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                        ),
                        child: const Text('발동'),
                      ),
                    )),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showReportSheet(MapSessionState mapState) async {
    final deadPlayers = mapState.eliminatedUserIds
        .map((userId) => mapState.members[userId])
        .whereType<MemberState>()
        .toList();

    if (deadPlayers.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('신고할 시체가 없습니다.')));
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('시체 신고',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
            for (final p in deadPlayers)
              ListTile(
                title: Text(p.nickname),
                subtitle: Text(p.userId),
                trailing: TextButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    ref
                        .read(gameProvider(widget.sessionId).notifier)
                        .sendReport(p.userId);
                  },
                  child: const Text('신고'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ── 플러그인 컨텍스트 생성 ──────────────────────────────────────────
  void _openMissionSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MissionListSheet(sessionId: widget.sessionId),
    );
  }

  void _openQrScanner() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => QrScannerScreen(sessionId: widget.sessionId),
      ),
    );
  }

  GamePluginCtx _buildPluginCtx({
    required AmongUsGameState gameState,
    required MapSessionState mapState,
    required String? myUserId,
    required bool isGhostMode,
    required bool isInProgress,
    required double chatBarH,
    required bool canKill,
    required bool canOpenVote,
    required bool canShowMission,
    required bool isImpostor,
  }) {
    final readyMissions = gameState.myMissions
        .where((m) =>
            m.type.isMapBased && m.status == MissionStatus.ready)
        .toList();
    final isOutOfBounds = gameState.isOutOfBounds;

    return GamePluginCtx(
      sessionId: widget.sessionId,
      gameState: gameState,
      mapState: mapState,
      myUserId: myUserId,
      isGhostMode: isGhostMode,
      isInProgress: isInProgress,
      chatBarH: chatBarH,
      // Kill
      canKill: canKill && !isOutOfBounds,
      killCooldown: _killCooldownSecs,
      killLabel: widget.sessionType == SessionType.chase ? '태그' : '제거',
      onKill: canKill && !isOutOfBounds && _killCooldownSecs == 0
          ? () {
              final targetId = mapState.proximateTargetId;
              if (targetId != null) {
                _handleKill(targetId);
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('근처에 대상이 없습니다.')),
                );
              }
            }
          : null,
      // Meeting
      canCallMeeting: canOpenVote && !isOutOfBounds,
      isMeetingCoolingDown: gameState.isMeetingCoolingDown,
      onCallMeeting: () {
        ref.read(gameProvider(widget.sessionId).notifier).callMeeting((res) {
          if (!mounted || res['ok'] == true) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(res['error']?.toString() ?? '회의를 소집할 수 없습니다.'),
              duration: const Duration(seconds: 2),
            ),
          );
        });
      },
      // Report
      canReport: widget.sessionType == SessionType.verbal &&
          !isGhostMode &&
          !isOutOfBounds &&
          mapState.eliminatedUserIds.isNotEmpty,
      onReport: () => _showReportSheet(mapState),
      // Mission / QR
      canShowMission: canShowMission && isInProgress && !isGhostMode && !isOutOfBounds,
      onShowMission: _openMissionSheet,
      onQrScan: _openQrScanner,
      // Sabotage
      canSabotage: isInProgress && isImpostor && !isGhostMode && !isOutOfBounds,
      onSabotage: () => _openSabotageSheet(gameState.myMissions),
      // Location extras
      isOutOfBounds: isOutOfBounds,
      boundsAlertPulse: _boundsAlertPulse,
      readyLocationMissions: readyMissions,
      onPerformMission: readyMissions.isNotEmpty
          ? () => _performLocationMission(readyMissions.first)
          : null,
    );
  }

  Future<void> _performLocationMission(Mission mission) async {
    final notifier = ref.read(gameProvider(widget.sessionId).notifier);
    final messenger = ScaffoldMessenger.of(context);
    switch (mission.type) {
      case MissionType.coinCollect:
        final result = await notifier.collectNearestCoinFor(mission.id);
        if (!mounted) return;
        if (result == null) {
          messenger.showSnackBar(const SnackBar(
            content: Text('범위를 벗어났습니다. 코인 10m 이내로 이동하세요.'),
            duration: Duration(seconds: 1),
          ));
        } else if (result) {
          messenger.showSnackBar(const SnackBar(
            content: Text('모든 코인을 수집했습니다! 미션 완료'),
            backgroundColor: Color(0xFF22C55E),
            duration: Duration(milliseconds: 1200),
          ));
        } else {
          messenger.showSnackBar(const SnackBar(
            content: Text('코인을 수집했습니다.'),
            duration: Duration(seconds: 1),
          ));
        }
        break;
      case MissionType.captureAnimal:
        final ok = await notifier.captureAnimalFor(mission.id);
        if (!mounted) return;
        if (ok) {
          messenger.showSnackBar(const SnackBar(
            content: Text('동물을 포획했습니다! 미션 완료'),
            backgroundColor: Color(0xFF22C55E),
            duration: Duration(milliseconds: 1200),
          ));
        } else {
          messenger.showSnackBar(const SnackBar(
            content: Text('범위를 벗어났습니다. 동물 5m 이내로 이동하세요.'),
            duration: Duration(seconds: 1),
          ));
        }
        break;
      case MissionType.minigame:
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => MinigameWrapperScreen(
            sessionId: widget.sessionId,
            mission: mission,
          ),
        ));
        break;
    }
  }

  // ──────────────────────────────────────────────────────────────────
  // ref.listen 반응 핸들러
  // ──────────────────────────────────────────────────────────────────

  /// gameProvider 상태 전이에 반응한다.
  /// - 역할 화면 / 결과 화면 라우팅
  /// - 플레이 영역 / 이탈 / 미션 마커 → 지도 오버레이 재동기화
  /// - 회의 시작 푸시
  void _handleGameStateChanged(
    AmongUsGameState? previous,
    AmongUsGameState next,
  ) {
    if (next.shouldNavigateToRole && !_roleNavDone) {
      _roleNavDone = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.push('/game/${widget.sessionId}/role');
        ref
            .read(gameProvider(widget.sessionId).notifier)
            .resetRoleNavigation();
      });
    }
    if (previous?.gameOverWinner == null && next.gameOverWinner != null) {
      final winner = next.gameOverWinner!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.go('/game/${widget.sessionId}/result/$winner');
      });
    }

    // 플레이 영역 변경 감지 → 폴리곤 재렌더링
    // (이탈 판정 자체는 GameNotifier가 GPS 스트림으로 수행)
    final prevArea = previous?.playableArea;
    final nextArea = next.playableArea;
    if (!identical(prevArea, nextArea)) {
      unawaited(_overlayCoordinator.applyPlayableAreaPolygon());
    }

    // 이탈 상태 변경 → 펄스 애니메이션 토글
    if (previous?.isOutOfBounds != next.isOutOfBounds) {
      if (next.isOutOfBounds) {
        _startBoundsPulse();
      } else {
        _stopBoundsPulse();
      }
    }

    // 미션 마커(코인/동물) 변경 → 오버레이 전체 재동기화
    if (previous?.missionCoins != next.missionCoins ||
        previous?.missionAnimals != next.missionAnimals) {
      unawaited(_overlayCoordinator.syncOverlays());
    }

    // 회의 시작 시 GameMeetingScreen 푸시
    if (previous?.shouldNavigateToMeeting != true &&
        next.shouldNavigateToMeeting) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final mapState = ref.read(mapSessionProvider(widget.sessionId));
        final authUser = ref.read(authProvider).valueOrNull;
        final memberNames = {
          for (final e in mapState.members.entries) e.key: e.value.nickname
        };
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => GameMeetingScreen(
            sessionId: widget.sessionId,
            memberNames: memberNames,
            myUserId: authUser?.id ?? '',
          ),
        ));
        ref
            .read(gameProvider(widget.sessionId).notifier)
            .resetMeetingNavigation();
      });
    }
  }

  /// mapSessionProvider 상태 전이에 반응한다.
  /// - 강제 퇴장 → 홈으로 이동
  /// - 멤버/숨김/탈락 변경 → 유저 마커 동기화
  void _handleMapStateChanged(
    MapSessionState? previous,
    MapSessionState next,
  ) {
    if (previous?.wasKicked != true && next.wasKicked) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.go(AppRoutes.home);
      });
    }

    final authUser = ref.read(authProvider).valueOrNull;
    if (!identical(previous?.members, next.members) ||
        !identical(previous?.hiddenMembers, next.hiddenMembers) ||
        !identical(previous?.eliminatedUserIds, next.eliminatedUserIds)) {
      unawaited(_overlayCoordinator.syncUserMarkers(
        next.members,
        authUser?.id,
        next.hiddenMembers,
        next.eliminatedUserIds,
      ));
    }

    // 내 위치가 바뀌고 추적 모드일 때만 카메라 이동 (build 안이 아닌 여기서 처리)
    final prevPos = previous?.myPosition;
    final nextPos = next.myPosition;
    if (_followMe &&
        nextPos != null &&
        _mapController != null &&
        (prevPos?.latitude != nextPos.latitude ||
            prevPos?.longitude != nextPos.longitude)) {
      _mapController!.updateCamera(
        NCameraUpdate.scrollAndZoomTo(
          target: NLatLng(nextPos.latitude, nextPos.longitude),
        )..setAnimation(animation: NCameraAnimation.easing),
      );
    }
  }

  // ──────────────────────────────────────────────────────────────────
  // BUILD
  // ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    ref.listen<AmongUsGameState>(
      gameProvider(widget.sessionId),
      _handleGameStateChanged,
    );
    ref.listen<MapSessionState>(
      mapSessionProvider(widget.sessionId),
      _handleMapStateChanged,
    );

    final gameState = ref.watch(gameProvider(widget.sessionId));
    final mapState = ref.watch(mapSessionProvider(widget.sessionId));
    final authUser = ref.watch(authProvider).valueOrNull;
    final myUserId = authUser?.id;
    final isGhostMode =
        myUserId != null && mapState.eliminatedUserIds.contains(myUserId);

    final activeModules = _getActiveModules();
    final isInProgress = mapState.gameState.status == 'in_progress';
    final isDefaultMode = widget.sessionType == SessionType.defaultType;

    // 미션 진행도
    final progressCompleted =
        (gameState.missionProgress['completed'] as num?)?.toInt() ?? 0;
    final progressTotal =
        (gameState.missionProgress['total'] as num?)?.toInt() ?? 0;
    final rawPercent =
        (gameState.missionProgress['percent'] as num?)?.toDouble() ??
            (progressTotal > 0 ? progressCompleted / progressTotal : 0);
    final progress = ((rawPercent > 1 ? rawPercent / 100 : rawPercent)
            .clamp(0.0, 1.0) as num)
        .toDouble();

    final myPos = mapState.myPosition;

    final winnerId = mapState.gameState.winnerId;
    final winnerName = winnerId != null
        ? (mapState.members[winnerId]?.nickname ?? winnerId)
        : '-';

    // AI 채팅 하단 패널 높이 계산
    final bottomSafe = MediaQuery.of(context).padding.bottom;
    final chatBarH = _aiChatExpanded
        ? _kChatHandleH + _kChatContentH
        : _kChatHandleH + bottomSafe;

    // 액션 가능 여부
    final isImpostor = gameState.myRole?.isImpostor == true;
    final canUseKill = (activeModules.contains('proximity') ||
            widget.sessionType == SessionType.chase) &&
        !isGhostMode &&
        isInProgress;
    final canOpenVote = activeModules.contains('round') &&
        activeModules.contains('vote') &&
        !isGhostMode &&
        isInProgress;
    final canShowMission = widget.sessionType == SessionType.location ||
        activeModules.contains('mission');

    // 플러그인 컨텍스트 생성
    final pluginCtx = _buildPluginCtx(
      gameState: gameState,
      mapState: mapState,
      myUserId: myUserId,
      isGhostMode: isGhostMode,
      isInProgress: isInProgress,
      chatBarH: chatBarH,
      canKill: canUseKill,
      canOpenVote: canOpenVote,
      canShowMission: canShowMission,
      isImpostor: isImpostor,
    );

    final showHostStart = mapState.myRole == 'host' &&
        mapState.gameState.status == 'none' &&
        !gameState.isStarted;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_showSessionInfo) {
          _closeSessionInfo();
        } else {
          _openSessionInfo();
        }
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            // ── Layer 1: NaverMap 배경 ─────────────────────────────
            if (_mapSdkReady)
              Positioned.fill(
                child: NaverMap(
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
                    try {
                      controller.setLocationTrackingMode(
                        NLocationTrackingMode.noFollow,
                      );
                    } catch (e) {
                      debugPrint('[GameMain] initial tracking mode 실패: $e');
                    }
                    // 지도 준비 후 현재 멤버 마커 + 폴리곤 + 미션 오버레이 적용
                    final ms = ref.read(mapSessionProvider(widget.sessionId));
                    final au = ref.read(authProvider).valueOrNull;
                    unawaited(_overlayCoordinator.syncUserMarkers(
                      ms.members,
                      au?.id,
                      ms.hiddenMembers,
                      ms.eliminatedUserIds,
                    ));
                    unawaited(_overlayCoordinator.syncOverlays());
                  },
                  onCameraChange: (reason, animated) {
                    if (reason == NCameraUpdateReason.gesture) {
                      setState(() => _followMe = false);
                      // follow → 사용자 제스처로 해제되면 Naver는 tracking
                      // 모드를 none으로 떨어뜨려 overlay까지 감출 수 있다.
                      // noFollow로 되돌려 위치·방향 오버레이는 유지.
                      try {
                        _mapController?.setLocationTrackingMode(
                          NLocationTrackingMode.noFollow,
                        );
                      } catch (_) {}
                    }
                  },
                ),
              )
            else
              const Positioned.fill(
                child: ColoredBox(
                  color: Color(0xFF0F172A),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ),

            // ── Layer 2: 반투명 상단 헤더 ───────────────────────────
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GameMainTopHeader(
                onBack: _openSessionInfo,
                onLeave: _confirmLeaveGame,
                role: !isDefaultMode ? gameState.myRole : null,
                progress: progress,
                completed: progressCompleted,
                total: progressTotal,
                showProgressBar: !isDefaultMode,
                isConnected: mapState.isConnected,
              ),
            ),

            // ── Layer 3: 우측 플로팅 컨트롤 (내 위치 / 줌 맞춤) ──────
            Positioned(
              right: 12,
              top: MediaQuery.of(context).padding.top + 96,
              child: GameMainRightFloatingControls(
                followMe: _followMe,
                onFollow: () => unawaited(_onMyLocationPressed()),
                onFit: () => _fitAllMembers(mapState.members, myPos),
                onMembers: () => _openMemberSheet(mapState, myUserId),
                onAiChat: null,
              ),
            ),

            // ── Layer 4: SOS 배너 ──────────────────────────────────
            if (mapState.sosTriggered) const GameMainSosBanner(),

            // ── Layer 5: 우상단 보조 칩 (생존자 / 라운드) ────────────
            if (isInProgress && mapState.gameState.aliveCount > 0)
              Positioned(
                top: MediaQuery.of(context).padding.top + 76,
                left: 16,
                child: GameMainInfoChip(
                    label: '생존 ${mapState.gameState.aliveCount}명'),
              ),

            // ── Layer 5b: 게임 보이스 채널 연결 버튼 ────────────────
            Positioned(
              top: MediaQuery.of(context).padding.top + 116,
              left: 16,
              child: GameMainVoiceChannelButton(
                connected: _gameVoiceConnected,
                connecting: _gameVoiceConnecting,
                onConnect: _connectGameVoice,
                onDisconnect: _disconnectGameVoice,
              ),
            ),

            // ── Layer 6~7: 모드 플러그인 스택 레이어 ──────────────────
            // (태거 칩, 위치 미션 버튼, 구역 이탈 경고 등 모드별 레이어)
            ..._modePlugin.buildStackLayers(context, pluginCtx),

            // ── Layer 8: 하단 액션 영역 (모드 플러그인 위임) ─────────────
            Positioned(
              left: 0,
              right: 0,
              bottom: chatBarH + 8,
              child: _modePlugin.buildBottomActions(context, pluginCtx),
            ),

            // ── Layer 9: 호스트 게임 시작 버튼 ───────────────────────
            if (showHostStart)
              GameMainHostStartButton(
                bottomOffset: chatBarH + 96,
                onStart: () => ref
                    .read(gameProvider(widget.sessionId).notifier)
                    .startGame(),
              ),

            // ── Layer 10: 유령 모드 오버레이 ─────────────────────────
            if (isGhostMode) const GameMainGhostOverlay(),

            // ── Layer 12: 게임 종료 오버레이 ─────────────────────────
            if (mapState.gameState.status == 'finished')
              GameMainGameOverOverlay(
                winnerId: winnerId,
                winnerName: winnerName,
                myUserId: myUserId,
              ),

            // ── Layer 14: AI 채팅 하단 패널 (항상 표시) ─────────────
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: GameMainAiChatBar(
                sessionId: widget.sessionId,
                isGhostMode: isGhostMode,
                expanded: _aiChatExpanded,
                handleH: _kChatHandleH,
                contentH: _kChatContentH,
                onToggle: () =>
                    setState(() => _aiChatExpanded = !_aiChatExpanded),
              ),
            ),

            // ── Layer 13: 세션 정보 오버레이 (뒤로가기 시 표시) ──────
            if (_showSessionInfo)
              GameMainSessionInfoOverlay(
                sessionId: widget.sessionId,
                gameType: 'among_us',
                onClose: _closeSessionInfo,
              ),
          ],
        ),
      ),
    );
  }
}
