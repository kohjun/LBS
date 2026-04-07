// lib/core/services/fcm_service.dart

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter/foundation.dart';
import '../network/api_client.dart';

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
  @pragma('vm:entry-point')
  static Future<void> onBackgroundMessage(RemoteMessage message) async {
    debugPrint('[FCM] 백그라운드 데이터 메시지 수신: ${message.data}');

    // 서버에서 {"type": "wakeUp"} 데이터를 보냈을 경우
    if (message.data['type'] == 'wakeUp') {
      // 실행 중인 백그라운드 서비스에 'wakeUp' 이벤트 전달
      FlutterBackgroundService().invoke('wakeUp');
    }
  }
}