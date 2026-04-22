// lib/features/auth/data/auth_repository.dart

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';
import '../../../core/services/background_service.dart';
import '../../../core/services/fcm_service.dart';
import '../../../core/services/socket_service.dart';

// 현재 로그인 사용자 모델
class AppUser {
  final String id;
  final String email;
  final String nickname;
  final String? avatarUrl;

  const AppUser({
    required this.id,
    required this.email,
    required this.nickname,
    this.avatarUrl,
  });

  factory AppUser.fromMap(Map<String, dynamic> map) => AppUser(
        id:        map['id']        as String,
        email:     map['email']     as String,
        nickname:  map['nickname']  as String,
        avatarUrl: map['avatar_url'] as String?,
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Auth Repository
// ─────────────────────────────────────────────────────────────────────────────
class AuthRepository {
  final ApiClient _api = ApiClient();

  Future<AppUser> register({
    required String email,
    required String password,
    required String nickname,
  }) async {
    final response = await _api.post('/auth/register', data: {
      'email':    email,
      'password': password,
      'nickname': nickname,
    });
    return AppUser.fromMap(response.data['user'] as Map<String, dynamic>);
  }

  Future<AppUser> login({
    required String email,
    required String password,
  }) async {
    final response = await _api.post('/auth/login', data: {
      'email':    email,
      'password': password,
    });

    final accessToken  = response.data['accessToken']  as String;
    final refreshToken = response.data['refreshToken'] as String?;
    await _api.saveTokens(accessToken: accessToken, refreshToken: refreshToken);

    return AppUser.fromMap(response.data['user'] as Map<String, dynamic>);
  }

  Future<void> logout() async {
    try {
      await _api.post('/auth/logout');
    } finally {
      await _api.clearTokens();
    }
  }

  Future<AppUser?> getMe() async {
    try {
      final response = await _api.get('/auth/me');
      return AppUser.fromMap(response.data['user'] as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Riverpod Provider
// ─────────────────────────────────────────────────────────────────────────────
final authRepositoryProvider = Provider((ref) => AuthRepository());

// 현재 로그인 사용자 상태
class AuthNotifier extends AsyncNotifier<AppUser?> {
  Future<void> _clearLocalSessionState() async {
    SocketService().leaveSession(notifyServer: false);
    SocketService().disconnect();
    await shutdownBackgroundService();
    await FcmService().dispose();
  }

  @override
  Future<AppUser?> build() async {
    // 401 복구 실패 시 자동 로그아웃 (build 완료 후 실행)
    ApiClient.onUnauthenticated = () {
      Future.microtask(() async {
        if (state.valueOrNull == null) {
          return;
        }
        await _clearLocalSessionState();
        state = const AsyncData(null);
      });
    };
    // 앱 시작 시 저장된 토큰으로 사용자 복원
    final user = await ref.read(authRepositoryProvider).getMe();
    if (user != null) {
      unawaited(FcmService().init());
    }
    return user;
  }

  Future<void> login({required String email, required String password}) async {
    state = const AsyncLoading();
    try {
      final user = await ref.read(authRepositoryProvider).login(
        email: email,
        password: password,
      );
      state = AsyncData(user);
      unawaited(FcmService().init());
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> register({
    required String email,
    required String password,
    required String nickname,
  }) async {
    state = const AsyncLoading();
    try {
      await ref.read(authRepositoryProvider).register(
        email: email,
        password: password,
        nickname: nickname,
      );
      // 등록 후 자동 로그인
      await login(email: email, password: password);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> logout() async {
    try {
      await _clearLocalSessionState();
      await ref.read(authRepositoryProvider).logout();
    } finally {
      state = const AsyncData(null);
    }
  }
}

final authProvider = AsyncNotifierProvider<AuthNotifier, AppUser?>(AuthNotifier.new);
