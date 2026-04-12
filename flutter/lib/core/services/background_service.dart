// lib/core/services/background_service.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

// 방금 만든 알림 서비스 임포트
import 'notification_service.dart';

const notificationChannelId = 'location_tracking_channel';
const notificationId = 888;

Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();

  // 안드로이드 알림 채널 설정
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    notificationChannelId, // id
    '실시간 위치 공유', // title
    description: '세션이 유지되는 동안 위치를 공유합니다.', // description
    importance: Importance.low, // low로 해야 알림 소리가 계속 나지 않음
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false, // 앱 켜지자마자가 아니라 세션 방 들어갈 때 켤 예정
      isForegroundMode: true,
      notificationChannelId: notificationChannelId,
      initialNotificationTitle: '위치 공유 중',
      initialNotificationContent: '백그라운드에서 위치를 업데이트하고 있습니다',
      foregroundServiceNotificationId: notificationId,
      foregroundServiceTypes: [AndroidForegroundType.location],
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

// iOS 전용 백그라운드 핸들러
@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

// 백그라운드 서비스가 시작될 때 실행되는 메인 진입점
@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  await NotificationService().init();

  final prefs = await SharedPreferences.getInstance();
  final token = prefs.getString('bg_token');
  final sessionId = prefs.getString('bg_session_id');
  final serverUrl = prefs.getString('bg_server_url') ?? 'http://10.0.2.2:3000';

  if (token == null || sessionId == null) {
    service.stopSelf();
    return;
  }

  // 상태 관리 변수
  io.Socket? socket;
  StreamSubscription<Position>? positionSub;
  Timer? idleTimer;
  bool isIdle = false;
  Position? prevPos;
  final Set<String> insideGeofences = {};
  final battery = Battery();
  String currentToken = token;

  // 토큰 갱신: /auth/refresh 호출 → 새 accessToken·refreshToken 저장
  Future<bool> refreshAccessToken() async {
    try {
      final uri = Uri.parse('$serverUrl/auth/refresh');
      final client = HttpClient();
      final req = await client.postUrl(uri);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');

      // 저장된 refresh_token이 있으면 body에 실어 전송 (쿠키 없는 환경 대응)
      final storedRefreshToken = prefs.getString('bg_refresh_token');
      if (storedRefreshToken != null) {
        final bodyBytes =
            utf8.encode(jsonEncode({'refreshToken': storedRefreshToken}));
        req.headers.set(HttpHeaders.contentLengthHeader, bodyBytes.length);
        req.add(bodyBytes);
      }

      final resp = await req.close();
      if (resp.statusCode != 200) {
        client.close(force: true);
        return false;
      }
      final body = await resp.transform(utf8.decoder).join();
      client.close(force: true);
      final Map<String, dynamic> data =
          jsonDecode(body) as Map<String, dynamic>;

      final newAccessToken = data['accessToken'] as String?;
      final newRefreshToken = data['refreshToken'] as String?;
      if (newAccessToken == null) return false;

      await prefs.setString('bg_token', newAccessToken);
      currentToken = newAccessToken;
      if (newRefreshToken != null) {
        await prefs.setString('bg_refresh_token', newRefreshToken);
      }
      return true;
    } catch (e) {
      debugPrint('[Background] 토큰 갱신 실패: $e');
      return false;
    }
  }

  // 1. 소켓 연결 함수
  void connectSocket() {
    if (socket?.connected == true) return;
    socket?.dispose();
    socket = io.io(
      serverUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .setExtraHeaders({'Authorization': 'Bearer $currentToken'})
          .enableForceNew() // 새로운 연결 강제
          .build(),
    );
    socket!.onConnect((_) => debugPrint('[Background] 소켓 연결됨'));
    socket!.onConnectError((err) async {
      debugPrint('[Background] 소켓 연결 에러: $err');
      try {
        if (err != null && err.toString().contains('AUTH_FAILED')) {
          final ok = await refreshAccessToken();
          if (ok) {
            connectSocket();
          } else {
            debugPrint('[Background] 토큰 갱신 실패 → 서비스 종료');
            service.stopSelf();
          }
        }
      } catch (e) {
        debugPrint('[Background] onConnectError 처리 중 예외: $e');
        service.stopSelf();
      }
    });
  }

  // ★ 에러 해결: late 키워드 사용으로 forward reference 해결
  // 2. 정지 감지 타이머 (5분간 큰 이동 없으면 절전 모드 진입)
  late Function({required bool idle}) startTracking;

  void resetIdleTimer() {
    idleTimer?.cancel();
    idleTimer = Timer(const Duration(minutes: 5), () {
      debugPrint('[Background] 5분간 정지. 절전 모드 진입');
      socket?.disconnect(); // 소켓 연결 끊어 배터리 절약
      startTracking(idle: true); // GPS 주기 완화
    });
  }

  // 3. 위치 추적 시작 함수 (동적 설정)
  startTracking = ({required bool idle}) {
    positionSub?.cancel();
    isIdle = idle;

    // ★ 에러 해결: const 제거 (AndroidSettings는 const 생성자를 지원하지 않음)
    final settings = idle
        ? AndroidSettings(
            accuracy: LocationAccuracy.medium,
            distanceFilter: 50, // 50m 이동 시 갱신
            intervalDuration: const Duration(seconds: 30),
          )
        : AndroidSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 5, // 5m 이동 시 갱신
            intervalDuration: const Duration(seconds: 5),
            foregroundNotificationConfig: const ForegroundNotificationConfig(
              notificationTitle: "실시간 위치 공유 중",
              notificationText: "정밀 위치 추적 모드 활성화",
            ),
          );

    positionSub = Geolocator.getPositionStream(locationSettings: settings)
        .listen((pos) async {
      // 1. 정지 타이머 초기화 (움직임 감지)
      resetIdleTimer();

      // 2. 절전 모드 해제: 현재 리스너가 끝난 뒤 startTracking 호출
      if (isIdle) {
        debugPrint('[Background] 이동 감지! 절전 모드 해제');
        connectSocket();
        Future.microtask(() => startTracking(idle: false));
        return;
      }

      // 2-1. 포그라운드 UI가 활성 상태면 백그라운드 송신은 건너뛴다
      // (UI 소켓이 이미 같은 위치를 전송하므로 중복 방지)
      try {
        await prefs.reload();
      } catch (_) {}
      final bgActive = prefs.getBool('bg_active') ?? false;
      if (bgActive) {
        prevPos = pos;
        return;
      }

      // 3. 배터리 레벨 읽기
      int? batteryLevel;
      try {
        batteryLevel = await battery.batteryLevel;
      } catch (e) {
        debugPrint('[Background] 배터리 레벨 읽기 실패: $e');
        batteryLevel = null;
      }

      // 3-1. 이전 위치와 비교해 실제 이동 여부 판정
      String moveStatus = 'moving';
      if (prevPos != null) {
        final d = Geolocator.distanceBetween(
          prevPos!.latitude,
          prevPos!.longitude,
          pos.latitude,
          pos.longitude,
        );
        moveStatus = d < 2 ? 'stopped' : 'moving';
      }

      // 4. 소켓 전송
      if (socket?.connected == true) {
        socket!.emit('location:update', {
          'sessionId': sessionId,
          'lat': pos.latitude,
          'lng': pos.longitude,
          'accuracy': pos.accuracy,
          'speed': pos.speed.isNaN ? null : pos.speed,
          'heading': pos.heading.isNaN ? null : pos.heading,
          'battery': batteryLevel,
          'status': moveStatus,
        });
      }
      prevPos = pos;

      // 5. 지오펜스 판정
      _checkGeofencesInBg(pos, sessionId, prefs, insideGeofences);
    }, onError: (Object error, StackTrace stackTrace) {
      debugPrint('[Background] 위치 스트림 에러: $error');
      positionSub?.cancel();
      idleTimer?.cancel();
      socket?.dispose();
      service.stopSelf();
    }, cancelOnError: true);
  };

  // 외부(FCM)로부터 기상 명령 수신
  service.on('wakeUp').listen((event) {
    debugPrint('[Background] 기상 명령 수신! 소켓 재연결');
    connectSocket();
    startTracking(idle: false);
  });

  // 서비스 중지 명령이 들어오면 전부 정리하고 종료
  service.on('stopService').listen((event) {
    positionSub?.cancel();
    idleTimer?.cancel();
    socket?.dispose();
    service.stopSelf();
    debugPrint('[Background] 서비스 및 소켓 정상 종료');
  });

  // 초기 실행
  connectSocket();
  startTracking(idle: false);
}

// ─────────────────────────────────────────────────────────────────────────────
// 지오펜스 판정 헬퍼 함수 (Top-level)
// ─────────────────────────────────────────────────────────────────────────────
void _checkGeofencesInBg(Position pos, String sessionId,
    SharedPreferences prefs, Set<String> insideGeofences) {
  final geofenceString = prefs.getString('geofences_$sessionId');
  if (geofenceString != null) {
    try {
      final List<dynamic> geofences = jsonDecode(geofenceString);

      for (final gf in geofences) {
        final double gfLat = gf['lat'] ?? 0.0;
        final double gfLng = gf['lng'] ?? 0.0;
        final double gfRadius = (gf['radius'] ?? 0.0).toDouble();
        final String gfId = gf['id']?.toString() ?? '';
        final String gfName = gf['name']?.toString() ?? '목표 지역';

        double distance = Geolocator.distanceBetween(
          pos.latitude,
          pos.longitude,
          gfLat,
          gfLng,
        );

        bool isCurrentlyInside = distance <= gfRadius;
        bool wasInside = insideGeofences.contains(gfId);

        if (isCurrentlyInside && !wasInside) {
          insideGeofences.add(gfId);
          NotificationService()
              .showNotification('지오펜스 진입', '$gfName 영역에 들어왔습니다!');
        } else if (!isCurrentlyInside && wasInside) {
          insideGeofences.remove(gfId);
          NotificationService()
              .showNotification('지오펜스 이탈', '$gfName 영역을 벗어났습니다.');
        }
      }
    } catch (e) {
      debugPrint('[Background] 지오펜스 파싱 에러: $e');
    }
  }
}
