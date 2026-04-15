// lib/features/game/presentation/minigames/wire_fix_game.dart
//
// 단순 미니게임: 중앙 텍스트 박스를 3번 터치하면 완료됩니다.

import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/material.dart';

class WireFixGame extends FlameGame with TapCallbacks {
  WireFixGame({required this.onComplete});

  final VoidCallback onComplete;

  int _tapCount = 0;
  static const int _targetTaps = 3;

  late TextComponent _instructionText;
  late TextComponent _countText;
  late RectangleComponent _box;
  bool _completed = false;

  @override
  Color backgroundColor() => const Color(0xFF0F0A2A);

  @override
  Future<void> onLoad() async {
    final center = size / 2;

    // 배경 박스
    _box = RectangleComponent(
      size: Vector2(240, 120),
      position: center - Vector2(120, 60),
      paint: Paint()..color = const Color(0xFF1E1B4B),
    );
    add(_box);

    // 테두리
    add(
      RectangleComponent(
        size: Vector2(242, 122),
        position: center - Vector2(121, 61),
        paint: Paint()
          ..color = const Color(0xFF6366F1)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      ),
    );

    // 안내 텍스트
    _instructionText = TextComponent(
      text: '전선 수리',
      position: center - Vector2(50, 20),
      textRenderer: TextPaint(
        style: const TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
    add(_instructionText);

    // 카운트 텍스트
    _countText = TextComponent(
      text: '탭: 0 / $_targetTaps',
      position: center + Vector2(-40, 12),
      textRenderer: TextPaint(
        style: const TextStyle(
          color: Color(0xFFA5B4FC),
          fontSize: 14,
        ),
      ),
    );
    add(_countText);

    // 하단 힌트
    add(
      TextComponent(
        text: '박스를 $_targetTaps번 탭하세요',
        position: center + Vector2(-80, 70),
        textRenderer: TextPaint(
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  @override
  void onTapDown(TapDownEvent event) {
    if (_completed) return;

    final center = size / 2;
    final boxRect = Rect.fromCenter(
      center: Offset(center.x, center.y),
      width: 240,
      height: 120,
    );
    final tapPos = Offset(event.canvasPosition.x, event.canvasPosition.y);

    if (!boxRect.contains(tapPos)) return;

    _tapCount++;
    _countText.text = '탭: $_tapCount / $_targetTaps';

    _box.paint = Paint()
      ..color = Color.lerp(
        const Color(0xFF1E1B4B),
        const Color(0xFF4F46E5),
        _tapCount / _targetTaps,
      )!;

    if (_tapCount >= _targetTaps) {
      _completed = true;
      _instructionText.text = '완료!';
      _countText.text = '미션 성공';
      Future.delayed(const Duration(milliseconds: 600), onComplete);
    }
  }
}
