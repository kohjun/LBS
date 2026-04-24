import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../providers/fantasy_wars_provider.dart';
import 'fw_duel_minigames_v2.dart';

class FwDuelScreen extends ConsumerWidget {
  const FwDuelScreen({
    super.key,
    required this.sessionId,
    required this.duel,
  });

  final String sessionId;
  final FwDuelState duel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(fantasyWarsProvider(sessionId).notifier);
    final params = duel.minigameParams ?? const <String, dynamic>{};

    void submit(Map<String, dynamic> result) => notifier.submitMinigame(result);

    late final Widget game;
    switch (duel.minigameType) {
      case 'reaction_time':
        game = ReactionTimeGame(
          onSubmit: submit,
          signalDelayMs: (params['signalDelayMs'] as num?)?.toInt() ?? 1000,
        );
        break;
      case 'rapid_tap':
        game = RapidTapGame(
          onSubmit: submit,
          durationSec: (params['durationSec'] as num?)?.toInt() ?? 5,
        );
        break;
      case 'precision':
        game = PrecisionGame(
          onSubmit: submit,
          targets: _parseTargets(params['targets']),
        );
        break;
      case 'russian_roulette':
        game = RussianRouletteGame(onSubmit: submit);
        break;
      case 'speed_blackjack':
        game = SpeedBlackjackGame(
          onSubmit: submit,
          initialHand: _parseIntList(params['hand'], const [10, 7]),
          drawPile: _parseIntList(params['drawPile'], const []),
          timeoutSec: (params['timeoutSec'] as num?)?.toInt() ?? 15,
        );
        break;
      default:
        game = _UnknownMinigame(
          type: duel.minigameType ?? '?',
          onSubmit: submit,
        );
        break;
    }

    return Positioned.fill(
      child: Material(
        color: Colors.transparent,
        child: Stack(
          children: [
            Positioned.fill(child: game),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  color: Colors.black.withValues(alpha: 0.72),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.sports_mma,
                        color: Colors.purpleAccent,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '대결 ${_minigameLabel(duel.minigameType)}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      const Spacer(),
                      if (!duel.submitted)
                        GestureDetector(
                          onTap: notifier.cancelDuel,
                          child: const Text(
                            '포기',
                            style: TextStyle(
                              color: Colors.redAccent,
                              fontSize: 13,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (duel.submitted)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.72),
                  child: const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(color: Colors.white),
                        SizedBox(height: 16),
                        Text(
                          '결과 대기 중...',
                          style: TextStyle(color: Colors.white70, fontSize: 15),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static List<int> _parseIntList(Object? raw, List<int> fallback) {
    return (raw as List?)
            ?.map((value) => (value as num).toInt())
            .toList(growable: false) ??
        fallback;
  }

  static List<Offset> _parseTargets(Object? raw) {
    final parsed = (raw as List?)
            ?.whereType<Map>()
            .map(
              (target) => Offset(
                (((target['x'] as num?)?.toDouble() ?? 0.5).clamp(0.05, 0.95))
                    .toDouble(),
                (((target['y'] as num?)?.toDouble() ?? 0.5).clamp(0.08, 0.92))
                    .toDouble(),
              ),
            )
            .toList(growable: false) ??
        const <Offset>[];

    if (parsed.isNotEmpty) {
      return parsed;
    }

    return const [
      Offset(0.25, 0.28),
      Offset(0.72, 0.46),
      Offset(0.42, 0.72),
    ];
  }

  static String _minigameLabel(String? type) => switch (type) {
        'reaction_time' => '반응 속도',
        'rapid_tap' => '연타',
        'precision' => '정밀 타격',
        'russian_roulette' => '러시안 룰렛',
        'speed_blackjack' => '스피드 블랙잭',
        _ => type ?? '?',
      };
}

class _UnknownMinigame extends StatelessWidget {
  const _UnknownMinigame({
    required this.type,
    required this.onSubmit,
  });

  final String type;
  final DuelSubmitCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF0F0A2A),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '알 수 없는 미니게임: $type',
              style: const TextStyle(color: Colors.redAccent, fontSize: 15),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => onSubmit({'reactionMs': 9999}),
              child: const Text('기권 처리'),
            ),
          ],
        ),
      ),
    );
  }
}
