// lib/features/game/presentation/minigames/card_swipe_game.dart
//
// 카드 긁기 미니게임: 카드를 오른쪽으로 드래그하면 미션 완료.

import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/material.dart';

class CardSwipeGame extends FlameGame {
  CardSwipeGame({required this.onComplete});

  final VoidCallback onComplete;

  bool _completed = false;

  @override
  Color backgroundColor() => const Color(0xFF0F0A2A);

  @override
  Future<void> onLoad() async {
    final center = size / 2;

    // 배경 힌트 텍스트
    add(
      TextComponent(
        text: '카드를 오른쪽으로 밀어내세요',
        position: Vector2(center.x - 120, center.y - 100),
        textRenderer: TextPaint(
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 14,
          ),
        ),
      ),
    );

    // 드래그 가능 카드
    final card = CardComponent(
      position: center,
      onComplete: _handleComplete,
    );
    add(card);
  }

  void _handleComplete() {
    if (_completed) return;
    _completed = true;
    Future.delayed(const Duration(milliseconds: 400), onComplete);
  }
}

class CardComponent extends PositionComponent with DragCallbacks {
  CardComponent({
    required Vector2 position,
    required this.onComplete,
  }) : super(
          position: position,
          size: Vector2(160, 100),
          anchor: Anchor.center,
        );

  final VoidCallback onComplete;

  static const double _startX = -150.0;
  static const double _endX = 150.0;

  double _dragOffsetX = 0.0;
  bool _done = false;

  late RectangleComponent _cardRect;
  late TextComponent _label;

  @override
  Future<void> onLoad() async {
    _cardRect = RectangleComponent(
      size: size,
      paint: Paint()..color = const Color(0xFF1E1B4B),
    );
    add(_cardRect);

    // 테두리
    add(
      RectangleComponent(
        size: size,
        paint: Paint()
          ..color = const Color(0xFF6366F1)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      ),
    );

    _label = TextComponent(
      text: '>>> 밀기',
      position: Vector2(size.x / 2, size.y / 2),
      anchor: Anchor.center,
      textRenderer: TextPaint(
        style: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
    add(_label);
  }

  @override
  void onDragUpdate(DragUpdateEvent event) {
    if (_done) return;
    _dragOffsetX += event.localDelta.x;
    // x 범위 클램프
    _dragOffsetX = _dragOffsetX.clamp(_startX, _endX);
    position.x = (parent as FlameGame).size.x / 2 + _dragOffsetX;

    // 진행도에 따라 색상 변경
    final progress = (_dragOffsetX - _startX) / (_endX - _startX);
    _cardRect.paint = Paint()
      ..color = Color.lerp(
        const Color(0xFF1E1B4B),
        const Color(0xFF16A34A),
        progress,
      )!;

    if (_dragOffsetX >= _endX) {
      _done = true;
      _label.text = '완료!';
      onComplete();
    }
  }

  @override
  void onDragEnd(DragEndEvent event) {
    super.onDragEnd(event);
    if (_done) return;
    // 완료 안 됐으면 원위치로
    _dragOffsetX = 0.0;
    position.x = (parent as FlameGame).size.x / 2;
    _cardRect.paint = Paint()..color = const Color(0xFF1E1B4B);
  }
}
