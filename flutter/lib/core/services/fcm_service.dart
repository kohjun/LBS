// lib/core/services/fcm_service.dart

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'; // WidgetsFlutterBinding
import 'package:shared_preferences/shared_preferences.dart';
import '../network/api_client.dart';

// ※ flutter_background_service 는 메인 UI Isolate 전용입니다.
//    FCM 백그라운드 핸들러는 별도 Isolate에서 실행되므로 직접 invoke() 를
//    호출할 수 없습니다. 대신 SharedPreferences 플래그를 통해
//    백그라운드 서비스에 기상 명령을 전달합니다.

class FcmService {
  static final FcmService _instance = FcmService._internal();
  factory FcmService() => _instance;
  FcmService._internal();

  final _api = ApiClient();

  Future<void> _saveTokenToServer(String token) async {
    try {
      await _api.patch('/auth/fcm-token', data: {'token': token});
    } catch (e) {
      debugPrint('[FCM] 토큰 서버 저장 실패: $e');
    }
  }

  Future<void> init() async {
    FirebaseMessaging messaging = FirebaseMessaging.instance;

    // 알림 권한 요청
    await messaging.requestPermission(alert: true, badge: true, sound: true);

    // 토큰 획득 및 서버 저장
    final token = await messaging.getToken();
    debugPrint('[FCM] Token: $token');
    if (token != null) await _saveTokenToServer(token);

    // 토큰 갱신 시 서버에 재저장
    messaging.onTokenRefresh.listen(_saveTokenToServer);

    // 포그라운드 메시지 핸들링
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      debugPrint('[FCM] 포그라운드 메시지 수신: ${message.data}');
    });
  }

  // ★ 백그라운드 메시지 핸들러 (최상단 함수여야 함)
  // 이 함수는 Firebase가 생성한 별도 Dart Isolate에서 실행됩니다.
  // FlutterBackgroundService().invoke()는 메인 UI Isolate 전용이므로
  // 호출하면 "This class should only be used in the main isolate" 예외가 발생합니다.
  // 대신 SharedPreferences 플래그를 통해 백그라운드 서비스에 기상 명령을 전달합니다.
  @pragma('vm:entry-point')
  static Future<void> onBackgroundMessage(RemoteMessage message) async {
    // 플러그인 사용 전 반드시 바인딩을 초기화해야 합니다
    WidgetsFlutterBinding.ensureInitialized();

    debugPrint('[FCM] 백그라운드 데이터 메시지 수신: ${message.data}');

    // 서버에서 {"type": "wakeUp"} 데이터를 보냈을 경우:
    // SharedPreferences에 플래그를 설정합니다.
    // background_service.dart의 폴링 타이머가 이 플래그를 감지하면
    // connectSocket() + startTracking()을 실행합니다.
    if (message.data['type'] == 'wakeUp') {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('bg_wakeup_requested', true);
        debugPrint('[FCM] wakeUp 플래그 설정 완료 → 백그라운드 서비스가 다음 폴링 시 반응합니다');
      } catch (e) {
        debugPrint('[FCM] wakeUp 플래그 설정 실패: $e');
      }
    }
  }
}