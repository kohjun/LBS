import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class GameResultScreen extends StatelessWidget {
  const GameResultScreen({
    super.key,
    required this.sessionId,
    required this.winner,
    this.reason,
  });

  final String sessionId;
  final String winner;
  final String? reason;

  @override
  Widget build(BuildContext context) {
    final isCrewWin = winner == 'crew';
    final isImpostorWin = winner == 'impostor';
    final backgroundColor = isCrewWin
        ? Colors.blue.shade900
        : isImpostorWin
            ? Colors.red.shade900
            : const Color(0xFF243447);
    final title = isCrewWin
        ? '크루 승리'
        : isImpostorWin
            ? '임포스터 승리'
            : '게임 종료';
    final subtitle = isCrewWin
        ? '크루가 승리했습니다.'
        : isImpostorWin
            ? '임포스터가 승리했습니다.'
            : winner;
    final icon = isCrewWin
        ? Icons.groups_rounded
        : isImpostorWin
            ? Icons.warning_rounded
            : Icons.emoji_events_rounded;

    return Scaffold(
      backgroundColor: backgroundColor,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 88, color: Colors.white),
                const SizedBox(height: 24),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 36,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  subtitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 18,
                  ),
                ),
                if (reason != null && reason!.trim().isNotEmpty) ...[
                  const SizedBox(height: 28),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Text(
                      reason!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 40),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black87,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 40,
                      vertical: 14,
                    ),
                    textStyle: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  onPressed: () => context.go('/'),
                  child: const Text('로비로 돌아가기'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
