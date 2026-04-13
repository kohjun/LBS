// lib/core/router/app_router.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/data/auth_repository.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../features/auth/presentation/register_screen.dart';
import '../../features/home/presentation/home_screen.dart';
import '../../features/map/presentation/map_screen.dart';
import '../../features/history/presentation/history_screen.dart';
import '../../features/geofence/presentation/geofence_screen.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/session/presentation/member_management_screen.dart';
import '../../features/game/presentation/game_main_screen.dart';
import '../../features/game/presentation/game_role_screen.dart';
import '../../features/game/presentation/game_result_screen.dart';
import '../../features/game/presentation/session_info_screen.dart';
import '../../features/lobby/presentation/lobby_screen.dart';
import '../../features/home/data/session_repository.dart';

// 라우트 경로 상수
abstract class AppRoutes {
  static const login = '/login';
  static const register = '/register';
  static const home = '/';
  static const lobby = '/lobby/:sessionId';
  static const game = '/game/:sessionId';
  static const map = '/map/:sessionId';
  static const history = '/history/:sessionId';
  static const geofence = '/geofence/:sessionId';
  static const settings = '/settings';
  static const members = '/session/:sessionId/members';
}

final routerProvider = Provider<GoRouter>((ref) {
  final authState = ref.watch(authProvider);

  return GoRouter(
    initialLocation: AppRoutes.home,
    redirect: (context, state) {
      final isLoggedIn = authState.valueOrNull != null;
      final isLoading = authState.isLoading;

      if (isLoading) return null;

      final isAuthRoute = state.matchedLocation == AppRoutes.login ||
          state.matchedLocation == AppRoutes.register;

      if (!isLoggedIn && !isAuthRoute) return AppRoutes.login;
      if (isLoggedIn && isAuthRoute) return AppRoutes.home;
      return null;
    },
    routes: [
      GoRoute(
        path: AppRoutes.login,
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: AppRoutes.register,
        builder: (context, state) => const RegisterScreen(),
      ),
      GoRoute(
        path: AppRoutes.home,
        builder: (context, state) => const HomeScreen(),
      ),
      GoRoute(
        path: AppRoutes.lobby,
        builder: (context, state) {
          final sessionId = state.pathParameters['sessionId']!;
          final sessionTypeStr =
              state.uri.queryParameters['sessionType'] ?? 'defaultType';
          final sessionType = SessionType.values.firstWhere(
            (t) => t.name == sessionTypeStr,
            orElse: () => SessionType.defaultType,
          );
          return LobbyScreen(
            sessionId: sessionId,
            sessionType: sessionType,
          );
        },
      ),
      GoRoute(
        path: AppRoutes.game,
        builder: (context, state) {
          final sessionId = state.pathParameters['sessionId']!;
          final typeStr = state.uri.queryParameters['type'] ?? 'defaultType';
          final sessionType = SessionType.values.firstWhere(
            (value) => value.name == typeStr,
            orElse: () => SessionType.defaultType,
          );
          return GameMainScreen(
            sessionId: sessionId,
            sessionType: sessionType,
          );
        },
      ),
      GoRoute(
        path: AppRoutes.map,
        builder: (context, state) {
          final sessionId = state.pathParameters['sessionId']!;
          return MapScreen(sessionId: sessionId);
        },
      ),
      GoRoute(
        path: AppRoutes.history,
        builder: (context, state) {
          final sessionId = state.pathParameters['sessionId']!;
          return HistoryScreen(sessionId: sessionId);
        },
      ),
      GoRoute(
        path: AppRoutes.geofence,
        builder: (context, state) {
          final sessionId = state.pathParameters['sessionId']!;
          return GeofenceScreen(sessionId: sessionId);
        },
      ),
      GoRoute(
        path: AppRoutes.settings,
        builder: (context, state) => const SettingsScreen(),
      ),
      GoRoute(
        path: AppRoutes.members,
        builder: (context, state) {
          final sessionId = state.pathParameters['sessionId']!;
          return MemberManagementScreen(sessionId: sessionId);
        },
      ),
      GoRoute(
        path: '/game/:sessionId/role',
        builder: (context, state) {
          final sessionId = state.pathParameters['sessionId']!;
          return GameRoleScreen(sessionId: sessionId);
        },
      ),
      // ← 뒤로가기 버튼 → 세션 정보 화면
      GoRoute(
        path: '/game/:sessionId/session-info',
        builder: (context, state) {
          final sessionId = state.pathParameters['sessionId']!;
          final typeStr =
              state.uri.queryParameters['type'] ?? 'defaultType';
          final sessionType = SessionType.values.firstWhere(
            (v) => v.name == typeStr,
            orElse: () => SessionType.defaultType,
          );
          return SessionInfoScreen(
            sessionId: sessionId,
            sessionType: sessionType,
          );
        },
      ),
      GoRoute(
        path: '/game/:sessionId/result/:winner',
        builder: (context, state) {
          final sessionId = state.pathParameters['sessionId']!;
          final winner = state.pathParameters['winner']!;
          final reason = state.uri.queryParameters['reason'];
          return GameResultScreen(
            sessionId: sessionId,
            winner: winner,
            reason: reason,
          );
        },
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(child: Text('페이지를 찾을 수 없습니다: ${state.error}')),
    ),
  );
});
