// lib/core/services/sound_service.dart
//
// 싱글턴 SoundService.
// audioplayers 패키지를 사용합니다.
// 실제 오디오 파일(assets/sounds/*.mp3)이 없어도 예외 없이 조용히 실패합니다.

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

class SoundService {
  // ── 싱글턴 ────────────────────────────────────────────────────────────────
  static final SoundService _instance = SoundService._internal();
  factory SoundService() => _instance;
  SoundService._internal();

  // 각 효과음마다 별도 플레이어 → 연속 재생 시 이전 소리가 끊기지 않음
  final AudioPlayer _startPlayer     = AudioPlayer();
  final AudioPlayer _overPlayer      = AudioPlayer();
  final AudioPlayer _killPlayer      = AudioPlayer();
  final AudioPlayer _emergencyPlayer = AudioPlayer();

  // ── 저수준 재생 ───────────────────────────────────────────────────────────
  Future<void> _play(AudioPlayer player, String assetPath) async {
    try {
      await player.stop();
      await player.play(AssetSource(assetPath));
    } catch (e) {
      // 오디오 파일이 아직 없거나 플랫폼 제한 → 조용히 무시
      debugPrint('[SoundService] 재생 실패 ($assetPath): $e');
    }
  }

  // ── 게임 이벤트 효과음 ────────────────────────────────────────────────────
  /// 게임 시작 효과음 (assets/sounds/start.mp3)
  Future<void> playGameStart() => _play(_startPlayer, 'sounds/start.mp3');

  /// 게임 종료 효과음 (assets/sounds/end.mp3)
  Future<void> playGameOver() => _play(_overPlayer, 'sounds/end.mp3');

  /// 킬 효과음 (assets/sounds/kill.mp3)
  Future<void> playKill() => _play(_killPlayer, 'sounds/kill.mp3');

  /// 긴급 회의 효과음 (assets/sounds/emergency.mp3)
  Future<void> playEmergency() => _play(_emergencyPlayer, 'sounds/emergency.mp3');
}
