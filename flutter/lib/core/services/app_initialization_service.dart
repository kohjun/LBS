import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'background_service.dart';
import '../../firebase_options.dart';

class AppInitializationService {
  AppInitializationService._internal();

  static final AppInitializationService _instance =
      AppInitializationService._internal();

  factory AppInitializationService() => _instance;

  Future<void>? _firebaseInitFuture;
  Future<void>? _naverMapInitFuture;
  Future<SharedPreferences>? _prefsFuture;

  bool _naverMapAuthFailed = false;
  bool get isNaverMapAuthFailed => _naverMapAuthFailed;

  void resetNaverMapAuthFailure() {
    _naverMapAuthFailed = false;
    _naverMapInitFuture = null;
  }

  /// SharedPreferences를 미리 로드해 둡니다.
  /// 이후 [SharedPreferences.getInstance] 호출은 캐시된 인스턴스를 즉시 반환합니다.
  Future<SharedPreferences> getPrefs() {
    _prefsFuture ??= SharedPreferences.getInstance();
    return _prefsFuture!;
  }

  Future<void> ensureFirebaseInitialized() {
    if (Firebase.apps.isNotEmpty) {
      return Future.value();
    }

    final existing = _firebaseInitFuture;
    if (existing != null) {
      return existing;
    }

    final future = _runTimed('Firebase.initializeApp', () async {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }).catchError((Object error, StackTrace stackTrace) {
      _firebaseInitFuture = null;
      throw error;
    });

    _firebaseInitFuture = future;
    return future;
  }

  Future<void> ensureNaverMapInitialized() {
    final existing = _naverMapInitFuture;
    if (existing != null) {
      return existing;
    }

    final future = _runTimed('Initialize Naver Map SDK', () async {
      await FlutterNaverMap().init(
        clientId: 'ir4goe1vir',
        onAuthFailed: (ex) {
          debugPrint('[NaverMap] Auth failed: $ex');
          _naverMapAuthFailed = true;
        },
      );
    }).catchError((Object error, StackTrace stackTrace) {
      _naverMapInitFuture = null;
      throw error;
    });

    _naverMapInitFuture = future;
    return future;
  }

  Future<void> resetBackgroundFlags() async {
    await _runTimed('Reset background flags', () async {
      await shutdownBackgroundService();
    });
  }

  Future<void> _runTimed(
    String label,
    Future<void> Function() action,
  ) async {
    await action();
  }
}
