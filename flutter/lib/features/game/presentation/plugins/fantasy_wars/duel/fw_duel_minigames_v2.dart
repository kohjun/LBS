import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

typedef DuelSubmitCallback = void Function(Map<String, dynamic> result);

class ReactionTimeGame extends StatefulWidget {
  const ReactionTimeGame({
    super.key,
    required this.onSubmit,
    required this.signalDelayMs,
  });

  final DuelSubmitCallback onSubmit;
  final int signalDelayMs;

  @override
  State<ReactionTimeGame> createState() => _ReactionTimeGameState();
}

class _ReactionTimeGameState extends State<ReactionTimeGame>
    with SingleTickerProviderStateMixin {
  final Stopwatch _stopwatch = Stopwatch();

  _ReactionPhase _phase = _ReactionPhase.ready;
  Timer? _signalTimer;
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  int? _reactionMs;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _pulseAnimation = Tween<double>(begin: 1, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _scheduleSignal();
  }

  void _scheduleSignal() {
    _signalTimer = Timer(
      Duration(milliseconds: widget.signalDelayMs),
      () {
        if (!mounted) {
          return;
        }
        _stopwatch
          ..reset()
          ..start();
        _pulseController.repeat(reverse: true);
        setState(() {
          _phase = _ReactionPhase.signal;
        });
      },
    );
  }

  void _submitFalseStart() {
    _signalTimer?.cancel();
    _pulseController.stop();
    setState(() {
      _phase = _ReactionPhase.done;
      _reactionMs = 9999;
    });
    Future<void>.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        widget.onSubmit({'reactionMs': 9999});
      }
    });
  }

  void _submitReaction() {
    _stopwatch.stop();
    _pulseController.stop();
    final reactionMs = _stopwatch.elapsedMilliseconds;
    setState(() {
      _phase = _ReactionPhase.done;
      _reactionMs = reactionMs;
    });
    Future<void>.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        widget.onSubmit({'reactionMs': reactionMs});
      }
    });
  }

  void _handleTap() {
    switch (_phase) {
      case _ReactionPhase.ready:
        _submitFalseStart();
        break;
      case _ReactionPhase.signal:
        _submitReaction();
        break;
      case _ReactionPhase.done:
        break;
    }
  }

  @override
  void dispose() {
    _signalTimer?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (background, title, subtitle, icon) = switch (_phase) {
      _ReactionPhase.ready => (
          const Color(0xFF122033),
          '신호를 기다리세요',
          '신호 전에 누르면 실패합니다.',
          Icons.hourglass_bottom,
        ),
      _ReactionPhase.signal => (
          const Color(0xFF166534),
          '지금!',
          '최대한 빠르게 터치하세요.',
          Icons.flash_on,
        ),
      _ReactionPhase.done => (
          const Color(0xFF1E1B4B),
          _reactionMs == 9999 ? '성급한 반응' : '${_reactionMs ?? 0} ms',
          '결과를 전송하는 중입니다.',
          Icons.check_circle,
        ),
    };

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _handleTap(),
      child: ColoredBox(
        color: background,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ScaleTransition(
                scale: _phase == _ReactionPhase.signal
                    ? _pulseAnimation
                    : const AlwaysStoppedAnimation(1),
                child: Icon(icon, color: Colors.white, size: 72),
              ),
              const SizedBox(height: 20),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                subtitle,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _ReactionPhase { ready, signal, done }

class RapidTapGame extends StatefulWidget {
  const RapidTapGame({
    super.key,
    required this.onSubmit,
    this.durationSec = 5,
  });

  final DuelSubmitCallback onSubmit;
  final int durationSec;

  @override
  State<RapidTapGame> createState() => _RapidTapGameState();
}

class _RapidTapGameState extends State<RapidTapGame>
    with SingleTickerProviderStateMixin {
  int _tapCount = 0;
  int _remainingMs = 0;
  int _startedAtMs = 0;
  bool _started = false;
  bool _submitted = false;

  Timer? _ticker;
  late final AnimationController _tapAnimationController;

  @override
  void initState() {
    super.initState();
    _remainingMs = widget.durationSec * 1000;
    _tapAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
  }

  void _startIfNeeded() {
    if (_started) {
      return;
    }

    _started = true;
    _startedAtMs = DateTime.now().millisecondsSinceEpoch;
    _ticker = Timer.periodic(const Duration(milliseconds: 50), (_) {
      final elapsed = DateTime.now().millisecondsSinceEpoch - _startedAtMs;
      final remaining = widget.durationSec * 1000 - elapsed;
      if (!mounted) {
        return;
      }
      if (remaining <= 0) {
        _finish();
        return;
      }
      setState(() {
        _remainingMs = remaining;
      });
    });
  }

  void _handleTap() {
    if (_submitted) {
      return;
    }

    _startIfNeeded();
    _tapAnimationController.forward(from: 0);
    setState(() {
      _tapCount += 1;
    });
  }

  void _finish() {
    if (_submitted) {
      return;
    }

    _ticker?.cancel();
    _submitted = true;
    final durationMs = _started
        ? DateTime.now().millisecondsSinceEpoch - _startedAtMs
        : widget.durationSec * 1000;
    setState(() {
      _remainingMs = 0;
    });
    Future<void>.delayed(const Duration(milliseconds: 250), () {
      if (mounted) {
        widget.onSubmit({
          'tapCount': _tapCount,
          'durationMs': max(durationMs, 1),
        });
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _tapAnimationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = widget.durationSec == 0
        ? 0.0
        : (_remainingMs / (widget.durationSec * 1000))
            .clamp(0.0, 1.0)
            .toDouble();

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _handleTap(),
      child: ColoredBox(
        color: const Color(0xFF1E1B4B),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 8,
                  backgroundColor: Colors.white12,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    progress > 0.3 ? const Color(0xFF8B5CF6) : Colors.redAccent,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                _submitted
                    ? '완료'
                    : _started
                        ? '${(_remainingMs / 1000).toStringAsFixed(1)} s'
                        : '터치해서 시작',
                style: const TextStyle(color: Colors.white70, fontSize: 16),
              ),
              const SizedBox(height: 12),
              Text(
                '$_tapCount',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 84,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 20),
              ScaleTransition(
                scale: Tween<double>(begin: 1, end: 0.9).animate(
                  CurvedAnimation(
                    parent: _tapAnimationController,
                    curve: Curves.easeOut,
                  ),
                ),
                child: Container(
                  width: 160,
                  height: 160,
                  decoration: BoxDecoration(
                    color: _submitted
                        ? Colors.grey
                        : const Color(0xFF8B5CF6),
                    shape: BoxShape.circle,
                    boxShadow: _submitted
                        ? null
                        : [
                            BoxShadow(
                              color: const Color(0xFF8B5CF6).withValues(alpha: 0.4),
                              blurRadius: 24,
                              spreadRadius: 6,
                            ),
                          ],
                  ),
                  child: const Icon(Icons.touch_app, color: Colors.white, size: 72),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PrecisionGame extends StatefulWidget {
  const PrecisionGame({
    super.key,
    required this.onSubmit,
    required this.targets,
  });

  final DuelSubmitCallback onSubmit;
  final List<Offset> targets;

  @override
  State<PrecisionGame> createState() => _PrecisionGameState();
}

class _PrecisionGameState extends State<PrecisionGame>
    with SingleTickerProviderStateMixin {
  final List<Map<String, double>> _submittedHits = [];
  final List<Offset> _hitMarkers = [];

  late final AnimationController _pulseController;
  Size _canvasSize = Size.zero;

  Offset get _currentTarget {
    if (widget.targets.isEmpty) {
      return Offset.zero;
    }
    final lastIndex = widget.targets.length - 1;
    final targetIndex = min(_submittedHits.length, lastIndex);
    return widget.targets[targetIndex];
  }

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  void _handleTap(TapDownDetails details) {
    if (_submittedHits.length >= widget.targets.length || _canvasSize == Size.zero) {
      return;
    }

    final localPosition = details.localPosition;
    final normalizedX =
        (localPosition.dx / _canvasSize.width).clamp(0.0, 1.0).toDouble();
    final normalizedY =
        (localPosition.dy / _canvasSize.height).clamp(0.0, 1.0).toDouble();

    setState(() {
      _submittedHits.add({'x': normalizedX, 'y': normalizedY});
      _hitMarkers.add(localPosition);
    });

    if (_submittedHits.length == widget.targets.length) {
      Future<void>.delayed(const Duration(milliseconds: 300), () {
        if (mounted) {
          widget.onSubmit({'hits': _submittedHits});
        }
      });
    }
  }

  Offset _toCanvasOffset(Offset normalized) {
    return Offset(
      normalized.dx * _canvasSize.width,
      normalized.dy * _canvasSize.height,
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF0F172A),
      child: LayoutBuilder(
        builder: (context, constraints) {
          _canvasSize = constraints.biggest;
          final targetPosition = _toCanvasOffset(_currentTarget);

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: _handleTap,
            child: Stack(
              children: [
                Positioned(
                  top: 16,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Text(
                      '${min(_submittedHits.length + 1, widget.targets.length)}/${widget.targets.length} 발',
                      style: const TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                  ),
                ),
                for (final marker in _hitMarkers)
                  Positioned(
                    left: marker.dx - 6,
                    top: marker.dy - 6,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: const BoxDecoration(
                        color: Colors.orangeAccent,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                AnimatedBuilder(
                  animation: _pulseController,
                  builder: (context, child) {
                    final radius = 28 + (_pulseController.value * 10);
                    return Positioned(
                      left: targetPosition.dx - radius,
                      top: targetPosition.dy - radius,
                      child: IgnorePointer(
                        child: Container(
                          width: radius * 2,
                          height: radius * 2,
                          decoration: BoxDecoration(
                            color: Colors.red.withValues(alpha: 0.12),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.redAccent,
                              width: 2.5,
                            ),
                          ),
                          child: const Icon(
                            Icons.add,
                            color: Colors.redAccent,
                            size: 22,
                          ),
                        ),
                      ),
                    );
                  },
                ),
                if (_submittedHits.length == widget.targets.length)
                  Positioned.fill(
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.55),
                      child: const Center(
                        child: Text(
                          '결과를 전송하는 중입니다.',
                          style: TextStyle(color: Colors.white70, fontSize: 15),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class RussianRouletteGame extends StatefulWidget {
  const RussianRouletteGame({super.key, required this.onSubmit});

  final DuelSubmitCallback onSubmit;

  @override
  State<RussianRouletteGame> createState() => _RussianRouletteGameState();
}

class _RussianRouletteGameState extends State<RussianRouletteGame>
    with SingleTickerProviderStateMixin {
  int? _selectedChamber;
  late final AnimationController _shakeController;
  late final Animation<double> _shakeAnimation;

  @override
  void initState() {
    super.initState();
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _shakeAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0, end: 6), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 6, end: -6), weight: 2),
      TweenSequenceItem(tween: Tween(begin: -6, end: 6), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 6, end: -4), weight: 2),
      TweenSequenceItem(tween: Tween(begin: -4, end: 0), weight: 1),
    ]).animate(_shakeController);
  }

  void _pickChamber(int chamber) {
    if (_selectedChamber != null) {
      return;
    }

    setState(() {
      _selectedChamber = chamber;
    });
    _shakeController.forward(from: 0);
    Future<void>.delayed(const Duration(milliseconds: 650), () {
      if (mounted) {
        widget.onSubmit({'chamber': chamber});
      }
    });
  }

  @override
  void dispose() {
    _shakeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF1A1018),
      child: Center(
        child: AnimatedBuilder(
          animation: _shakeAnimation,
          builder: (context, child) => Transform.translate(
            offset: Offset(_shakeAnimation.value, 0),
            child: child,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '약실을 선택하세요',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '6개 중 하나에만 실탄이 들어 있습니다.',
                style: TextStyle(color: Colors.white38, fontSize: 13),
              ),
              const SizedBox(height: 32),
              Wrap(
                spacing: 16,
                runSpacing: 16,
                alignment: WrapAlignment.center,
                children: List.generate(6, (index) {
                  final chamber = index + 1;
                  final isSelected = _selectedChamber == chamber;
                  return GestureDetector(
                    onTap: () => _pickChamber(chamber),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: isSelected
                            ? const Color(0xFF7F1D1D)
                            : const Color(0xFF374151),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isSelected ? Colors.red : Colors.white24,
                          width: 2,
                        ),
                      ),
                      child: Center(
                        child: Text(
                          '$chamber',
                          style: TextStyle(
                            color: isSelected ? Colors.red.shade100 : Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SpeedBlackjackGame extends StatefulWidget {
  const SpeedBlackjackGame({
    super.key,
    required this.onSubmit,
    required this.initialHand,
    required this.drawPile,
    this.timeoutSec = 15,
  });

  final DuelSubmitCallback onSubmit;
  final List<int> initialHand;
  final List<int> drawPile;
  final int timeoutSec;

  @override
  State<SpeedBlackjackGame> createState() => _SpeedBlackjackGameState();
}

class _SpeedBlackjackGameState extends State<SpeedBlackjackGame>
    with SingleTickerProviderStateMixin {
  late List<int> _hand;
  late int _remainingSec;
  int _hitCount = 0;
  bool _submitted = false;
  bool _showNewCard = false;

  Timer? _timer;
  late final AnimationController _bustAnimationController;
  late final Animation<double> _bustAnimation;

  int get _score {
    var total = _hand.fold<int>(0, (sum, card) => sum + card);
    var aces = _hand.where((card) => card == 11).length;
    while (total > 21 && aces > 0) {
      total -= 10;
      aces -= 1;
    }
    return total;
  }

  bool get _isBust => _score > 21;

  @override
  void initState() {
    super.initState();
    _hand = List<int>.from(widget.initialHand);
    _remainingSec = widget.timeoutSec;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        return;
      }
      if (_remainingSec <= 1) {
        _stand();
        return;
      }
      setState(() {
        _remainingSec -= 1;
      });
    });
    _bustAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );
    _bustAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0, end: 8), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 8, end: -8), weight: 2),
      TweenSequenceItem(tween: Tween(begin: -8, end: 8), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 8, end: 0), weight: 1),
    ]).animate(_bustAnimationController);
  }

  void _hit() {
    if (_submitted || _hitCount >= widget.drawPile.length) {
      _stand();
      return;
    }

    setState(() {
      _hand.add(widget.drawPile[_hitCount]);
      _hitCount += 1;
      _showNewCard = true;
    });

    Future<void>.delayed(const Duration(milliseconds: 450), () {
      if (mounted) {
        setState(() {
          _showNewCard = false;
        });
      }
    });

    if (_isBust) {
      _bustAnimationController.forward(from: 0);
      Future<void>.delayed(const Duration(milliseconds: 400), _stand);
    }
  }

  void _stand() {
    if (_submitted) {
      return;
    }

    _submitted = true;
    _timer?.cancel();
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      if (mounted) {
        widget.onSubmit({'hitCount': _hitCount});
      }
    });
    setState(() {});
  }

  String _cardLabel(int value) => value == 11 ? 'A' : '$value';

  @override
  void dispose() {
    _timer?.cancel();
    _bustAnimationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _bustAnimation,
      builder: (context, child) => Transform.translate(
        offset: Offset(_bustAnimation.value, 0),
        child: child,
      ),
      child: ColoredBox(
        color: const Color(0xFF064E3B),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.timer, color: Colors.white54, size: 16),
                  const SizedBox(width: 6),
                  Text(
                    '$_remainingSec s',
                    style: TextStyle(
                      color: _remainingSec <= 5 ? Colors.redAccent : Colors.white70,
                      fontSize: 14,
                      fontWeight: _remainingSec <= 5
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              const Text(
                '블랙잭',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  for (int index = 0; index < _hand.length; index += 1)
                    Container(
                      width: 48,
                      height: 68,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: [
                          BoxShadow(
                            color: index == _hand.length - 1 && _showNewCard
                                ? Colors.amber.withValues(alpha: 0.6)
                                : Colors.black26,
                            blurRadius: index == _hand.length - 1 && _showNewCard ? 12 : 4,
                          ),
                        ],
                      ),
                      child: Center(
                        child: Text(
                          _cardLabel(_hand[index]),
                          style: TextStyle(
                            color: _hand[index] == 11 ? Colors.red : Colors.black87,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 18),
              Text(
                _isBust ? 'BUST' : '합계: $_score',
                style: TextStyle(
                  color: _isBust ? Colors.redAccent : Colors.amber,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 28),
              if (!_submitted)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ElevatedButton(
                      onPressed: _hit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF8B5CF6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 28,
                          vertical: 14,
                        ),
                      ),
                      child: const Text('히트'),
                    ),
                    const SizedBox(width: 16),
                    ElevatedButton(
                      onPressed: _stand,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF374151),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 28,
                          vertical: 14,
                        ),
                      ),
                      child: const Text('스탠드'),
                    ),
                  ],
                )
              else
                const Text(
                  '결과를 전송하는 중입니다.',
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
