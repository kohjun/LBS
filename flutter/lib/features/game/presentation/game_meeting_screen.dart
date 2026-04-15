// lib/features/game/presentation/game_meeting_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/game_provider.dart';
import '../data/game_models.dart';

class GameMeetingScreen extends ConsumerStatefulWidget {
  const GameMeetingScreen({
    super.key,
    required this.sessionId,
    required this.memberNames, // {userId: nickname}
    required this.myUserId,
  });
  final String sessionId;
  final Map<String, String> memberNames;
  final String myUserId;

  @override
  ConsumerState<GameMeetingScreen> createState() => _GameMeetingScreenState();
}

class _GameMeetingScreenState extends ConsumerState<GameMeetingScreen> {
  String? _selectedTarget;
  bool _hasVoted    = false;
  bool _hasPreVoted = false;

  // meeting_ended 팝업을 한 번만 표시하기 위한 플래그
  bool _hasSeenActiveMeeting = false;
  bool _endHandled = false;

  @override
  void initState() {
    super.initState();
    final phase = ref.read(gameProvider(widget.sessionId)).meetingPhase;
    if (phase != 'none') _hasSeenActiveMeeting = true;
  }

  void _handleMeetingEnded() {
    if (_endHandled || !mounted) return;
    _endHandled = true;

    final result = ref.read(gameProvider(widget.sessionId)).voteResult;
    final ejectedId = result?.ejectedId;
    final ejectedNickname = ejectedId != null
        ? (widget.memberNames[ejectedId] ?? ejectedId)
        : null;

    final message = ejectedNickname != null
        ? '$ejectedNickname이(가) 추방되었습니다'
        : '아무도 추방되지 않았습니다';

    // widget이 unmount되어도 pop을 실행할 수 있도록 미리 캡처
    final navigator = Navigator.of(context);

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
          decoration: BoxDecoration(
            color: const Color(0xFF16213e),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: ejectedNickname != null
                  ? const Color(0xFFe94560)
                  : Colors.white24,
              width: 1.5,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (ejectedId != null) ...[
                const SizedBox(height: 12),
                Text(
                  result?.wasImpostor == true
                      ? '정체: 임포스터'
                      : '정체: 크루원',
                  style: TextStyle(
                    color: result?.wasImpostor == true
                        ? Colors.red.shade300
                        : Colors.blue.shade300,
                    fontSize: 15,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              const LinearProgressIndicator(
                backgroundColor: Color(0xFF0f3460),
                color: Color(0xFFe94560),
                minHeight: 3,
              ),
              const SizedBox(height: 8),
              const Text(
                '3초 후 게임으로 돌아갑니다',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );

    Future.delayed(const Duration(seconds: 3), () {
      // mounted 와 무관하게 캡처한 navigator로 pop (widget unmount 후에도 동작)
      if (navigator.canPop()) navigator.pop(); // 다이얼로그
      if (navigator.canPop()) navigator.pop(); // 회의 화면
    });
  }

  @override
  Widget build(BuildContext context) {
    final gameState = ref.watch(gameProvider(widget.sessionId));

    // meeting_ended 감지: 'none'이 되면 팝업 표시
    ref.listen(
      gameProvider(widget.sessionId).select((s) => s.meetingPhase),
      (prev, next) {
        if (next != 'none') {
          _hasSeenActiveMeeting = true;
        } else if (_hasSeenActiveMeeting) {
          _handleMeetingEnded();
        }
      },
    );

    return Scaffold(
      backgroundColor: const Color(0xFF1a1a2e),
      body: SafeArea(
        child: gameState.meetingPhase == 'result'
            ? _buildResultView(gameState)
            : _buildMeetingView(gameState),
      ),
    );
  }

  Widget _buildMeetingView(AmongUsGameState gameState) => Column(
        children: [
          _buildHeader(gameState),
          Expanded(child: _buildPlayerList(gameState)),
          _buildBottomActions(gameState),
        ],
      );

  // ── 상단 헤더 ──────────────────────────────────────────────────────────────
  Widget _buildHeader(AmongUsGameState gameState) {
    final isVoting  = gameState.meetingPhase == 'voting';
    final isDiscuss = gameState.meetingPhase == 'discussion';
    final remaining = gameState.meetingRemaining;
    final mins      = remaining ~/ 60;
    final secs      = remaining % 60;
    final timeStr   =
        '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';

    return Container(
      padding: const EdgeInsets.all(16),
      color: const Color(0xFF16213e),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                isVoting ? '투표 중' : '토론 중',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: remaining <= 10
                      ? Colors.red
                      : const Color(0xFF0f3460),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  timeStr,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (isVoting)
            Text(
              '${gameState.totalVoted} / ${gameState.totalPlayers}명 투표완료',
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
          if (isDiscuss)
            Text(
              '${gameState.preVoteCount} / ${gameState.totalPlayers}명 사전투표',
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
        ],
      ),
    );
  }

  // ── 플레이어 목록 ────────────────────────────────────────────────────────────
  Widget _buildPlayerList(AmongUsGameState gameState) {
    final isVoting  = gameState.meetingPhase == 'voting';
    final canSelect = !isVoting ? !_hasPreVoted : !_hasVoted;

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: widget.memberNames.length,
      itemBuilder: (context, index) {
        final userId   = widget.memberNames.keys.elementAt(index);
        final nickname = widget.memberNames[userId]!;
        final isMe     = userId == widget.myUserId;
        final selected = _selectedTarget == userId;

        return GestureDetector(
          onTap: (!isMe && canSelect)
              ? () => setState(() => _selectedTarget = userId)
              : null,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF16213e),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected
                    ? const Color(0xFFe94560)
                    : Colors.transparent,
                width: 2,
              ),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor:
                      isMe ? Colors.grey : const Color(0xFF0f3460),
                  child: Text(
                    nickname.isNotEmpty ? nickname[0].toUpperCase() : '?',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    isMe ? '$nickname (나)' : nickname,
                    style: TextStyle(
                      color: isMe ? Colors.grey : Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (selected)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFe94560),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      '선택됨',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── 하단 액션 ──────────────────────────────────────────────────────────────
  Widget _buildBottomActions(AmongUsGameState gameState) {
    final isVoting  = gameState.meetingPhase == 'voting';
    final isDiscuss = gameState.meetingPhase == 'discussion';

    return Container(
      padding: const EdgeInsets.all(16),
      color: const Color(0xFF16213e),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isDiscuss) ...[
            const Text(
              '토론 중 - 사전 투표가 가능합니다',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              '사전투표: ${gameState.preVoteCount}/${gameState.totalPlayers}명',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: (isVoting && _hasVoted) || (isDiscuss && _hasPreVoted)
                      ? null
                      : () {
                          setState(() => _selectedTarget = 'skip');
                          _handleVote();
                        },
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: (isVoting && _hasVoted) ||
                                (isDiscuss && _hasPreVoted)
                            ? Colors.white24
                            : Colors.white54,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Center(
                      child: Text(
                        '건너뛰기',
                        style: TextStyle(
                          color: (isVoting && _hasVoted) ||
                                  (isDiscuss && _hasPreVoted)
                              ? Colors.white24
                              : Colors.white70,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: GestureDetector(
                  onTap: (isVoting && _hasVoted) ||
                          (isDiscuss && _hasPreVoted) ||
                          _selectedTarget == null
                      ? null
                      : _handleVote,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      color: isVoting
                          ? (_hasVoted
                              ? Colors.grey
                              : const Color(0xFFe94560))
                          : (_hasPreVoted
                              ? Colors.grey
                              : const Color(0xFF0f3460)),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Center(
                      child: Text(
                        isVoting
                            ? (_hasVoted ? '투표 완료' : '투표 확정')
                            : (_hasPreVoted ? '사전 투표 완료' : '사전투표 확정'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _handleVote() {
    if (_selectedTarget == null) return;
    ref.read(gameProvider(widget.sessionId).notifier).sendVote(
      _selectedTarget!,
      (res) {
        if (!mounted) return;
        if (res['ok'] == true) {
          setState(() {
            if (res['preVote'] == true) {
              _hasPreVoted = true;
            } else {
              _hasVoted = true;
            }
          });
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(res['error']?.toString() ?? '투표 실패')),
          );
        }
      },
    );
  }

  // ── 결과 화면 ──────────────────────────────────────────────────────────────
  Widget _buildResultView(AmongUsGameState gameState) {
    final result = gameState.voteResult;

    String ejectedNickname = '알 수 없음';
    if (result?.ejectedId != null) {
      ejectedNickname =
          widget.memberNames[result!.ejectedId!] ?? result.ejectedId!;
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '투표 결과',
              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 24),
            if (result == null)
              const CircularProgressIndicator(color: Colors.white)
            else if (result.isTied)
              const Text(
                '동률 - 아무도 추방되지 않았습니다',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 18),
              )
            else if (result.ejectedId != null) ...[
              Text(
                '$ejectedNickname이(가)\n추방되었습니다',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                result.wasImpostor == true ? '임포스터였습니다' : '크루원이었습니다',
                style: TextStyle(
                  color: result.wasImpostor == true
                      ? Colors.red.shade300
                      : Colors.blue.shade300,
                  fontSize: 18,
                ),
              ),
            ],
            const SizedBox(height: 32),
            const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    color: Colors.white54,
                    strokeWidth: 2,
                  ),
                ),
                SizedBox(width: 12),
                Text(
                  '게임으로 돌아가는 중...',
                  style: TextStyle(color: Colors.white54, fontSize: 14),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
