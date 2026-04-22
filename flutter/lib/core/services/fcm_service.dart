import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_initialization_service.dart';
import '../network/api_client.dart';

class FcmService {
  static final FcmService _instance = FcmService._internal();

  factory FcmService() => _instance;

  FcmService._internal();

  final _api = ApiClient();

  bool _initialized = false;
  StreamSubscription<String>? _tokenRefreshSub;
  StreamSubscription<RemoteMessage>? _foregroundMessageSub;

  bool get isInitialized => _initialized;

  Future<void> _saveTokenToServer(String token) async {
    try {
      await _api.patch('/auth/fcm-token', data: {'token': token});
    } catch (e) {
      debugPrint('[FCM] Failed to sync token: $e');
    }
  }

  Future<void> init() async {
    if (_initialized) {
      debugPrint('[FCM] init skipped: already initialized');
      return;
    }

    final stopwatch = Stopwatch()..start();
    await AppInitializationService().ensureFirebaseInitialized();
    final messaging = FirebaseMessaging.instance;
    await messaging.setAutoInitEnabled(true);

    final settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    debugPrint(
      '[FCM] Notification permission: ${settings.authorizationStatus.name}',
    );

    final token = await messaging.getToken();
    debugPrint('[FCM] Token fetched: ${token != null}');
    if (token != null) {
      final prefs = await SharedPreferences.getInstance();
      final savedToken = prefs.getString('fcm_token');
      if (savedToken != token) {
        await _saveTokenToServer(token);
        await prefs.setString('fcm_token', token);
      }
    }

    _tokenRefreshSub = messaging.onTokenRefresh.listen((token) async {
      await _saveTokenToServer(token);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('fcm_token', token);
    });

    _foregroundMessageSub =
        FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      debugPrint('[FCM] Foreground message received: ${message.data}');
    });

    _initialized = true;
    debugPrint('[FCM] init completed in ${stopwatch.elapsedMilliseconds}ms');
  }

  @pragma('vm:entry-point')
  static Future<void> onBackgroundMessage(RemoteMessage message) async {
    // 백그라운드 isolate에서는 WidgetsFlutterBinding이 필요합니다.
    WidgetsFlutterBinding.ensureInitialized();
    await AppInitializationService().ensureFirebaseInitialized();

    debugPrint('[FCM] Background message received: ${message.data}');

    if (message.data['type'] == 'wakeUp') {
      try {
        // 캐시된 SP 인스턴스 사용 (디스크 재로드 방지)
        final prefs = await AppInitializationService().getPrefs();
        await prefs.setBool('bg_wakeup_requested', true);
        debugPrint('[FCM] wakeUp flag stored for background service');
      } catch (e) {
        debugPrint('[FCM] Failed to store wakeUp flag: $e');
      }
    }
  }

  Future<void> dispose() async {
    try {
      await FirebaseMessaging.instance.setAutoInitEnabled(false);
    } catch (e) {
      debugPrint('[FCM] Failed to disable auto init: $e');
    }
    await _tokenRefreshSub?.cancel();
    await _foregroundMessageSub?.cancel();
    _initialized = false;
  }
}
