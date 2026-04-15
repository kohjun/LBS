// lib/features/game/presentation/minigames/minigame_wrapper_screen.dart
//
// Flame 미니게임 래퍼 스크린.
// 게임 클리어 시 화면을 닫고 GameProvider.completeMission을 호출합니다.

import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/game_provider.dart';
import 'wire_fix_game.dart';

class MinigameWrapperScreen extends ConsumerStatefulWidget {
  const MinigameWrapperScreen({
    super.key,
    required this.sessionId,
    required this.missionId,
    required this.missionTitle,
  });

  final String sessionId;
  final String missionId;
  final String missionTitle;

  @override
  ConsumerState<MinigameWrapperScreen> createState() =>
      _MinigameWrapperScreenState();
}

class _MinigameWrapperScreenState extends ConsumerState<MinigameWrapperScreen> {
  late final WireFixGame _game;

  @override
  void initState() {
    super.initState();
    _game = WireFixGame(onComplete: _onGameComplete);
  }

  void _onGameComplete() {
    if (!mounted) return;

    ref.read(gameProvider(widget.sessionId).notifier)
        .completeMission(widget.missionId);

    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0A2A),
      body: SafeArea(
        child: Stack(
          children: [
            GameWidget(game: _game),
            // 상단 정보 바
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                color: Colors.black.withValues(alpha: 0.7),
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () => Navigator.of(context).maybePop(),
                      child: const Text(
                        '< 나가기',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      widget.missionTitle,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    const SizedBox(width: 48),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
