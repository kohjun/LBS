// lib/features/game/presentation/minigames/minigame_wrapper_screen.dart
//
// Flame 미니게임 래퍼 스크린.
// 게임 클리어 시 1.5s 처리 중 오버레이를 표시한 뒤 completeMission / fixSabotage를 호출합니다.

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/game_models.dart';
import '../../providers/game_provider.dart';
import 'minigame_registry.dart';

const _processingTexts = [
  '시스템 암호화 해제 중...',
  '보안 데이터 전송 중...',
  '서버 동기화 검증 중...',
  '미션 로그 업로드 중...',
  '통신 채널 암호화 중...',
];

class MinigameWrapperScreen extends ConsumerStatefulWidget {
  const MinigameWrapperScreen({
    super.key,
    required this.sessionId,
    required this.mission,
  });

  final String sessionId;
  final Mission mission;

  @override
  ConsumerState<MinigameWrapperScreen> createState() =>
      _MinigameWrapperScreenState();
}

class _MinigameWrapperScreenState
    extends ConsumerState<MinigameWrapperScreen> {
  bool _isProcessing = false;
  late final String _processingText;

  @override
  void initState() {
    super.initState();
    _processingText =
        _processingTexts[Random().nextInt(_processingTexts.length)];
  }

  void _onGameComplete() {
    if (_isProcessing || !mounted) return;
    setState(() => _isProcessing = true);

    Future.delayed(const Duration(milliseconds: 1500), () {
      if (!mounted) return;

      final notifier = ref.read(gameProvider(widget.sessionId).notifier);
      if (widget.mission.isSabotaged) {
        notifier.fixSabotage(widget.mission.id);
      } else {
        notifier.completeMission(widget.mission.id);
      }

      Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    // 사보타지 수리 모드에서는 wire_fix 게임을 강제
    final effectiveMinigameId =
        widget.mission.isSabotaged ? 'wire_fix' : widget.mission.minigameId;

    return Scaffold(
      backgroundColor: const Color(0xFF0F0A2A),
      body: SafeArea(
        child: Stack(
          children: [
            MinigameRegistry.getMinigameWidget(
              minigameId: effectiveMinigameId,
              onComplete: _onGameComplete,
            ),

            // ── 상단 정보 바 ──────────────────────────────────────────────
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
                      widget.mission.isSabotaged
                          ? '[수리] ${widget.mission.title}'
                          : widget.mission.title,
                      style: TextStyle(
                        color: widget.mission.isSabotaged
                            ? const Color(0xFFFFB347)
                            : Colors.white,
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

            // ── 처리 중 오버레이 ──────────────────────────────────────────
            if (_isProcessing)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.85),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        _processingText,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 24),
                      const SizedBox(
                        width: 220,
                        child: LinearProgressIndicator(
                          backgroundColor: Color(0xFF1E1B4B),
                          color: Color(0xFF6366F1),
                          minHeight: 4,
                        ),
                      ),
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
