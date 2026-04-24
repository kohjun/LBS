import 'package:flutter/material.dart';

import '../../../providers/fantasy_wars_provider.dart';

const _guildColors = <String, Color>{
  'guild_alpha': Color(0xFFEF4444),
  'guild_beta': Color(0xFF3B82F6),
  'guild_gamma': Color(0xFF22C55E),
  'guild_delta': Color(0xFFF59E0B),
};

Color guildColor(String? guildId) => _guildColors[guildId] ?? Colors.grey;

class FwTopHud extends StatelessWidget {
  const FwTopHud({
    super.key,
    required this.myState,
    required this.guilds,
    required this.aliveCount,
  });

  final FwMyState myState;
  final Map<String, FwGuildInfo> guilds;
  final int aliveCount;

  @override
  Widget build(BuildContext context) {
    final guild = guilds[myState.guildId];
    final color = guildColor(myState.guildId);
    final topInset = MediaQuery.of(context).padding.top;

    return Positioned(
      top: topInset + 8,
      left: 12,
      right: 84,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.74),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.65)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${guild?.displayName ?? myState.guildId ?? '-'} · ${_jobLabel(myState.job)}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '생존 $aliveCount',
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Stack(
              children: [
                Container(
                  height: 6,
                  decoration: BoxDecoration(
                    color: Colors.white12,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: (myState.hp / 100).clamp(0.0, 1.0),
                  child: Container(
                    height: 6,
                    decoration: BoxDecoration(
                      color: myState.hp > 40 ? Colors.greenAccent : Colors.redAccent,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'HP ${myState.hp}/100${myState.inDuel ? ' · 대결 중' : ''}',
              style: const TextStyle(color: Colors.white54, fontSize: 10),
            ),
            const SizedBox(height: 2),
            Text(
              _statusLine(myState),
              style: const TextStyle(color: Colors.white38, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }

  String _statusLine(FwMyState myState) {
    final parts = <String>[];
    if (myState.isGuildMaster) {
      parts.add('길드 마스터');
    }
    if (myState.job == 'warrior') {
      parts.add('목숨 ${myState.remainingLives}');
    }
    if (myState.shieldCount > 0) {
      parts.add('보호막 ${myState.shieldCount}');
    }
    if (myState.isBuffActive) {
      parts.add('버프 활성');
    }
    if (myState.isRevealActive && myState.trackedTargetUserId != null) {
      parts.add('추적 활성');
    }
    if (myState.isExecutionReady) {
      parts.add('처형 준비');
    }
    if (!myState.isAlive) {
      parts.add(myState.dungeonEntered ? '던전 대기' : '탈락');
    }
    return parts.isEmpty ? '스킬 준비' : parts.join(' · ');
  }

  String _jobLabel(String? job) => switch (job) {
        'warrior' => '전사',
        'priest' => '사제',
        'mage' => '마법사',
        'ranger' => '레인저',
        'rogue' => '도적',
        _ => job ?? '?',
      };
}

class FwWorldStatusPanel extends StatelessWidget {
  const FwWorldStatusPanel({
    super.key,
    required this.myState,
    required this.dungeons,
    required this.memberLabels,
    this.bleSummary,
    this.duelDebugLines = const [],
  });

  final FwMyState myState;
  final List<FwDungeonState> dungeons;
  final Map<String, String> memberLabels;
  final String? bleSummary;
  final List<String> duelDebugLines;

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;
    final dungeon = dungeons.isNotEmpty ? dungeons.first : null;
    final artifactHolder = dungeon?.artifact.heldBy;
    final artifactLabel =
        artifactHolder == null ? '미확보' : memberLabels[artifactHolder] ?? artifactHolder;
    final trackedLabel = myState.trackedTargetUserId == null
        ? null
        : memberLabels[myState.trackedTargetUserId!] ?? myState.trackedTargetUserId!;

    final rows = <String>[
      if (bleSummary != null) bleSummary!,
      if (dungeon != null) '${dungeon.displayName} · ${_dungeonLabel(dungeon.status)}',
      '성유물 · $artifactLabel',
      if (myState.isRevealActive && trackedLabel != null) '추적 대상 · $trackedLabel',
      if (!myState.isAlive && myState.dungeonEntered)
        '부활 대기 · ${(100 * (myState.nextReviveChance ?? 0.3)).round()}%',
    ];

    if (rows.isEmpty) {
      return const SizedBox.shrink();
    }

    return Positioned(
      top: topInset + 88,
      right: 12,
      child: Container(
        width: 182,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xCC101827),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '전장 정보',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            for (final row in rows) ...[
              Text(
                row,
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
              const SizedBox(height: 4),
            ],
            if (duelDebugLines.isNotEmpty) ...[
              const SizedBox(height: 6),
              Container(height: 1, color: Colors.white12),
              const SizedBox(height: 8),
              const Text(
                '결투 판정',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              for (final line in duelDebugLines) ...[
                Text(
                  line,
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
                const SizedBox(height: 4),
              ],
            ],
          ],
        ),
      ),
    );
  }

  String _dungeonLabel(String status) => switch (status) {
        'open' => '개방',
        'cleared' => '정리됨',
        'closed' => '폐쇄',
        _ => status,
      };
}

class FwControlPointChips extends StatelessWidget {
  const FwControlPointChips({
    super.key,
    required this.controlPoints,
    required this.myGuildId,
    this.bottomOffset = 0,
  });

  final List<FwControlPoint> controlPoints;
  final String? myGuildId;
  final double bottomOffset;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: bottomOffset + 8,
      child: SizedBox(
        height: 38,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          itemCount: controlPoints.length,
          separatorBuilder: (_, __) => const SizedBox(width: 6),
          itemBuilder: (_, index) => _CpChip(
            cp: controlPoints[index],
            myGuildId: myGuildId,
          ),
        ),
      ),
    );
  }
}

class _CpChip extends StatelessWidget {
  const _CpChip({required this.cp, this.myGuildId});

  final FwControlPoint cp;
  final String? myGuildId;

  @override
  Widget build(BuildContext context) {
    final owned = cp.capturedBy != null;
    final capturing = cp.capturingGuild != null;
    final isMyGuild = cp.capturedBy == myGuildId;

    Color borderColor;
    Color bgColor;
    if (cp.isBlockaded) {
      borderColor = Colors.redAccent;
      bgColor = Colors.redAccent.withValues(alpha: 0.16);
    } else if (owned && isMyGuild) {
      borderColor = guildColor(cp.capturedBy);
      bgColor = guildColor(cp.capturedBy).withValues(alpha: 0.24);
    } else if (owned) {
      borderColor = guildColor(cp.capturedBy).withValues(alpha: 0.72);
      bgColor = Colors.black.withValues(alpha: 0.62);
    } else if (capturing) {
      borderColor = guildColor(cp.capturingGuild).withValues(alpha: 0.82);
      bgColor = guildColor(cp.capturingGuild).withValues(alpha: 0.14);
    } else {
      borderColor = Colors.white24;
      bgColor = Colors.black.withValues(alpha: 0.62);
    }

    var label = cp.displayName;
    if (cp.isBlockaded) {
      label += ' [봉쇄]';
    } else if (cp.requiredCount > 0) {
      label += ' ${cp.readyCount}/${cp.requiredCount}';
    } else if (capturing) {
      label += ' [점령 중]';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor, width: 1.5),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: isMyGuild ? guildColor(cp.capturedBy) : Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class FwSkillButton extends StatelessWidget {
  const FwSkillButton({
    super.key,
    required this.job,
    required this.onPressed,
    required this.skillUsedAt,
    required this.bottomOffset,
  });

  final String? job;
  final VoidCallback? onPressed;
  final Map<String, int> skillUsedAt;
  final double bottomOffset;

  @override
  Widget build(BuildContext context) {
    final skill = _skillForJob(job);
    if (skill == null) {
      return const SizedBox.shrink();
    }

    final cooldownEndsAt = skillUsedAt[skill] ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    final remainMs = cooldownEndsAt - now;
    final onCooldown = remainMs > 0;
    final remainSec = onCooldown ? (remainMs / 1000).ceil() : 0;

    return Positioned(
      right: 16,
      bottom: bottomOffset + 16,
      child: GestureDetector(
        onTap: onCooldown ? null : onPressed,
        child: Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: onCooldown ? Colors.grey.shade800 : const Color(0xFF0F766E),
            border: Border.all(
              color: onCooldown ? Colors.grey : const Color(0xFF5EEAD4),
              width: 2,
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x44000000),
                blurRadius: 14,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                _skillLabel(skill),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (onCooldown)
                Text(
                  '${remainSec}s',
                  style: const TextStyle(color: Colors.white54, fontSize: 10),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String? _skillForJob(String? job) => switch (job) {
        'priest' => 'shield',
        'mage' => 'blockade',
        'ranger' => 'reveal',
        'rogue' => 'execution',
        _ => null,
      };

  String _skillLabel(String skill) => switch (skill) {
        'shield' => '보호막\n(사제)',
        'blockade' => '봉쇄\n(마법사)',
        'reveal' => '추적\n(레인저)',
        'execution' => '처형\n(도적)',
        _ => skill,
      };
}

class FwActionDock extends StatelessWidget {
  const FwActionDock({
    super.key,
    required this.bottomOffset,
    this.captureLabel,
    this.onCapture,
    this.duelLabel,
    this.onDuel,
    this.dungeonLabel,
    this.onDungeon,
  });

  final double bottomOffset;
  final String? captureLabel;
  final VoidCallback? onCapture;
  final String? duelLabel;
  final VoidCallback? onDuel;
  final String? dungeonLabel;
  final VoidCallback? onDungeon;

  @override
  Widget build(BuildContext context) {
    final actions = <Widget>[
      if (captureLabel != null)
        _ActionChip(
          label: captureLabel!,
          color: const Color(0xFF0F766E),
          onTap: onCapture,
        ),
      if (duelLabel != null)
        _ActionChip(
          label: duelLabel!,
          color: const Color(0xFF991B1B),
          onTap: onDuel,
        ),
      if (dungeonLabel != null)
        _ActionChip(
          label: dungeonLabel!,
          color: const Color(0xFF4338CA),
          onTap: onDungeon,
        ),
    ];

    if (actions.isEmpty) {
      return const SizedBox.shrink();
    }

    return Positioned(
      left: 12,
      bottom: bottomOffset + 16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final action in actions) ...[
            action,
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.label,
    required this.color,
    this.onTap,
  });

  final String label;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.88),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white24),
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class FwDuelChallengeDialog extends StatelessWidget {
  const FwDuelChallengeDialog({
    super.key,
    required this.duelId,
    required this.opponentId,
    required this.onAccept,
    required this.onReject,
  });

  final String duelId;
  final String? opponentId;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black54,
        child: Center(
          child: Container(
            margin: const EdgeInsets.all(32),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1B4B),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.purpleAccent),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '대결 도전',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${opponentId ?? '상대'}님이 1:1 대결을 요청했습니다.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    TextButton(
                      onPressed: onReject,
                      child: const Text(
                        '거절',
                        style: TextStyle(color: Colors.redAccent),
                      ),
                    ),
                    ElevatedButton(
                      onPressed: onAccept,
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.purple),
                      child: const Text('수락'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class FwChallengingIndicator extends StatelessWidget {
  const FwChallengingIndicator({
    super.key,
    required this.opponentId,
    required this.onCancel,
  });

  final String? opponentId;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black38,
        child: Center(
          child: Container(
            margin: const EdgeInsets.all(32),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xCC111827),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white24),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 14),
                Text(
                  '${opponentId ?? '상대'}에게 대결 요청 중',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                TextButton(
                  onPressed: onCancel,
                  child: const Text('취소'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class FwDuelResultOverlay extends StatelessWidget {
  const FwDuelResultOverlay({
    super.key,
    required this.result,
    required this.myId,
    required this.onClose,
  });

  final FwDuelResult result;
  final String? myId;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final isDraw = result.isDraw;
    final isWin = !isDraw && result.winnerId == myId;
    final title = switch ((isDraw, isWin)) {
      (true, _) => '무승부',
      (false, true) => '승리',
      _ => '패배',
    };
    final color = switch ((isDraw, isWin)) {
      (true, _) => Colors.orangeAccent,
      (false, true) => Colors.amber,
      _ => Colors.redAccent,
    };

    final detailParts = <String>[
      _reasonLabel(result.reason),
      if (result.shieldAbsorbed) '보호막 소모',
      if (result.executionTriggered) '처형 발동',
      if (result.warriorHpResult != null) '전사 잔여 목숨 ${result.warriorHpResult}',
    ];

    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black54,
        child: Center(
          child: GestureDetector(
            onTap: onClose,
            child: Container(
              margin: const EdgeInsets.all(28),
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: const Color(0xEE111827),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: color.withValues(alpha: 0.7), width: 2),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: color,
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    detailParts.where((part) => part.isNotEmpty).join(' · '),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _reasonLabel(String reason) => switch (reason) {
        'minigame' => '미니게임 판정',
        'opponent_timeout' => '상대 시간 초과',
        'both_timed_out' => '양측 시간 초과',
        'invalidated' => '무효 처리',
        _ => reason,
      };
}

class FwGameOverOverlay extends StatelessWidget {
  const FwGameOverOverlay({
    super.key,
    required this.winCondition,
    required this.myGuildId,
    required this.guilds,
    required this.onLeave,
  });

  final Map<String, dynamic> winCondition;
  final String? myGuildId;
  final Map<String, FwGuildInfo> guilds;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    final winner = winCondition['winner'] as String?;
    final reason = winCondition['reason'] as String?;
    final isWin = winner == myGuildId;
    final winnerGuild = guilds[winner];
    final color = isWin ? Colors.amber : Colors.grey;

    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.84),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                isWin ? '승리!' : '패배',
                style: TextStyle(
                  color: color,
                  fontSize: 40,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '${winnerGuild?.displayName ?? winner ?? '?'} 길드 승리',
                style: const TextStyle(color: Colors.white70, fontSize: 18),
              ),
              const SizedBox(height: 8),
              Text(
                _reasonLabel(reason),
                style: const TextStyle(color: Colors.white38, fontSize: 14),
              ),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: onLeave,
                child: const Text('나가기'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _reasonLabel(String? reason) => switch (reason) {
        'control_point_majority' => '거점 3개 점령',
        'guild_master_eliminated' => '상대 길드 마스터 제거',
        'last_standing_by_score' => '동시 탈락 후 점수 판정',
        _ => reason ?? '',
      };
}
