// lib/features/game/presentation/minigames/minigame_registry.dart
//
// 미니게임 플러그인 레지스트리.
// minigameId를 받아 해당 게임 위젯을 반환합니다.

import 'package:flame/game.dart';
import 'package:flutter/material.dart';

import 'card_swipe_game.dart';
import 'wire_fix_game.dart';

class MinigameRegistry {
  MinigameRegistry._();

  static Widget getMinigameWidget({
    required String minigameId,
    required VoidCallback onComplete,
  }) {
    switch (minigameId) {
      case 'wire_fix':
        return GameWidget(game: WireFixGame(onComplete: onComplete));
      case 'card_swipe':
        return GameWidget(game: CardSwipeGame(onComplete: onComplete));
      default:
        return _ErrorMinigame(
          minigameId: minigameId,
          onComplete: onComplete,
        );
    }
  }
}

class _ErrorMinigame extends StatelessWidget {
  const _ErrorMinigame({
    required this.minigameId,
    required this.onComplete,
  });

  final String minigameId;
  final VoidCallback onComplete;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF0F0A2A),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '알 수 없는 미니게임\n"$minigameId"',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.redAccent,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 24),
            GestureDetector(
              onTap: onComplete,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF4F46E5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  '강제 클리어',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
