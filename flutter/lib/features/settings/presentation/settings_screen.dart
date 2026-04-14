// lib/features/settings/presentation/settings_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../auth/data/auth_repository.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 설정 키 상수
// ─────────────────────────────────────────────────────────────────────────────
abstract class SettingsKeys {
  static const locationHistoryEnabled      = 'setting_location_history';
  static const geofenceNotificationsEnabled = 'setting_geofence_notifications';
  static const locationPrecision           = 'setting_location_precision';  // 'high' | 'battery'
  static const locationUpdateInterval      = 'setting_update_interval';     // 3 | 10 | 30 (초)
}

// ──────────────────────────────────── ─────────────────────────────────────────
// 설정 상태 모델
// ─────────────────────────────────────────────────────────────────────────────
class AppSettings {
  final bool locationHistoryEnabled;
  final bool geofenceNotificationsEnabled;
  final String locationPrecision;
  final int locationUpdateInterval;

  const AppSettings({
    this.locationHistoryEnabled       = true,
    this.geofenceNotificationsEnabled = true,
    this.locationPrecision            = 'high',
    this.locationUpdateInterval       = 10,
  });

  AppSettings copyWith({
    bool?   locationHistoryEnabled,
    bool?   geofenceNotificationsEnabled,
    String? locationPrecision,
    int?    locationUpdateInterval,
  }) =>
      AppSettings(
        locationHistoryEnabled:       locationHistoryEnabled       ?? this.locationHistoryEnabled,
        geofenceNotificationsEnabled: geofenceNotificationsEnabled ?? this.geofenceNotificationsEnabled,
        locationPrecision:            locationPrecision            ?? this.locationPrecision,
        locationUpdateInterval:       locationUpdateInterval       ?? this.locationUpdateInterval,
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// SettingsNotifier
// ─────────────────────────────────────────────────────────────────────────────
class SettingsNotifier extends AsyncNotifier<AppSettings> {
  @override
  Future<AppSettings> build() async {
    final prefs = await SharedPreferences.getInstance();
    return AppSettings(
      locationHistoryEnabled:
          prefs.getBool(SettingsKeys.locationHistoryEnabled) ?? true,
      geofenceNotificationsEnabled:
          prefs.getBool(SettingsKeys.geofenceNotificationsEnabled) ?? true,
      locationPrecision:
          prefs.getString(SettingsKeys.locationPrecision) ?? 'high',
      locationUpdateInterval:
          prefs.getInt(SettingsKeys.locationUpdateInterval) ?? 10,
    );
  }

  Future<void> _save(AppSettings updated) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(
        SettingsKeys.locationHistoryEnabled, updated.locationHistoryEnabled);
    await prefs.setBool(
        SettingsKeys.geofenceNotificationsEnabled, updated.geofenceNotificationsEnabled);
    await prefs.setString(
        SettingsKeys.locationPrecision, updated.locationPrecision);
    await prefs.setInt(
        SettingsKeys.locationUpdateInterval, updated.locationUpdateInterval);
    state = AsyncData(updated);
  }

  Future<void> setLocationHistory(bool v) async {
    final s = state.valueOrNull;
    if (s == null) return;
    await _save(s.copyWith(locationHistoryEnabled: v));
  }

  Future<void> setGeofenceNotifications(bool v) async {
    final s = state.valueOrNull;
    if (s == null) return;
    await _save(s.copyWith(geofenceNotificationsEnabled: v));
  }

  Future<void> setPrecision(String v) async {
    final s = state.valueOrNull;
    if (s == null) return;
    await _save(s.copyWith(locationPrecision: v));
  }

  Future<void> setUpdateInterval(int v) async {
    final s = state.valueOrNull;
    if (s == null) return;
    await _save(s.copyWith(locationUpdateInterval: v));
  }
}

final settingsProvider =
    AsyncNotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);

// ─────────────────────────────────────────────────────────────────────────────
// SettingsScreen
// ─────────────────────────────────────────────────────────────────────────────
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(settingsProvider);
    final user          = ref.watch(authProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(title: const Text('설정')),
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error:   (e, _) => Center(child: Text('설정 로드 실패: $e')),
        data:    (settings) => ListView(
          children: [
            // ── 계정 정보 ───────────────────────────────────────────────
            if (user != null) ...[
              const _SectionHeader('계정'),
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: const Color(0xFF2196F3).withValues(alpha: 0.15),
                  child: Text(
                    user.nickname.isNotEmpty
                        ? user.nickname[0].toUpperCase()
                        : '?',
                    style: const TextStyle(
                        color: Color(0xFF2196F3), fontWeight: FontWeight.bold),
                  ),
                ),
                title: Text(user.nickname,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(user.email),
              ),
              const Divider(),
            ],

            // ── 위치 기록 ───────────────────────────────────────────────
            const _SectionHeader('위치 기록'),
            SwitchListTile(
              secondary: const Icon(Icons.history),
              title: const Text('위치 기록 저장'),
              subtitle: const Text('이동 경로를 서버에 저장합니다'),
              value: settings.locationHistoryEnabled,
              onChanged: (v) =>
                  ref.read(settingsProvider.notifier).setLocationHistory(v),
            ),
            const Divider(),

            // ── 지오펜싱 ────────────────────────────────────────────────
            const _SectionHeader('지오펜싱'),
            SwitchListTile(
              secondary: const Icon(Icons.notifications_outlined),
              title: const Text('지오펜스 알림'),
              subtitle: const Text('구역 진입/이탈 시 알림을 받습니다'),
              value: settings.geofenceNotificationsEnabled,
              onChanged: (v) => ref
                  .read(settingsProvider.notifier)
                  .setGeofenceNotifications(v),
            ),
            const Divider(),

            // ── GPS 정밀도 ──────────────────────────────────────────────
            const _SectionHeader('GPS 설정'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '위치 공유 정밀도',
                    style: TextStyle(fontSize: 15),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'high',
                        label: Text('고정밀'),
                        icon: Icon(Icons.gps_fixed),
                      ),
                      ButtonSegment(
                        value: 'battery',
                        label: Text('배터리 절약'),
                        icon: Icon(Icons.battery_saver),
                      ),
                    ],
                    selected: {settings.locationPrecision},
                    onSelectionChanged: (s) =>
                        ref.read(settingsProvider.notifier).setPrecision(s.first),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // ── 업데이트 주기 ───────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '위치 업데이트 주기',
                    style: TextStyle(fontSize: 15),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 3,  label: Text('3초')),
                      ButtonSegment(value: 10, label: Text('10초')),
                      ButtonSegment(value: 30, label: Text('30초')),
                    ],
                    selected: {settings.locationUpdateInterval},
                    onSelectionChanged: (s) =>
                        ref.read(settingsProvider.notifier).setUpdateInterval(s.first),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const Divider(),

            // ── 로그아웃 ────────────────────────────────────────────────
            const _SectionHeader('계정 관리'),
            ListTile(
              leading: const Icon(Icons.logout, color: Colors.red),
              title: const Text(
                '로그아웃',
                style: TextStyle(color: Colors.red),
              ),
              onTap: () => _confirmLogout(context, ref),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  void _confirmLogout(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('로그아웃'),
        content: const Text('로그아웃하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(authProvider.notifier).logout();
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: const Text('로그아웃'),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: Colors.grey[500],
            letterSpacing: 0.5,
          ),
        ),
      );
}
