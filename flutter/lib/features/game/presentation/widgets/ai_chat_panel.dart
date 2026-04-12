import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../game/data/game_models.dart';
import '../../../game/providers/game_provider.dart';

class AIChatPanel extends ConsumerStatefulWidget {
  const AIChatPanel({
    super.key,
    required this.sessionId,
    this.isGhostMode = false, // ★ 추가됨: 유령 모드 여부
    this.height = double.infinity,
  });

  final String sessionId;
  final bool isGhostMode;
  final double height;

  @override
  ConsumerState<AIChatPanel> createState() => _AIChatPanelState();
}

class _AIChatPanelState extends ConsumerState<AIChatPanel> {
  final _controller = TextEditingController();
  final _scrollCtrl = ScrollController();
  
  int _prevLogCount = 0;
  bool _isAwaitingReply = false; // ★ 추가됨: AI 응답 대기 상태
  String? _pendingQuestion;

  @override
  void dispose() {
    _controller.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  void _sendMessage() {
    if (widget.isGhostMode || _isAwaitingReply) return;

    final text = _controller.text.trim();
    if (text.isEmpty) return;

    // 로딩 상태 시작
    setState(() {
      _isAwaitingReply = true;
      _pendingQuestion = text;
    });

    ref.read(gameProvider(widget.sessionId).notifier).askAI(text);
    _controller.clear();
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final gameState = ref.watch(gameProvider(widget.sessionId));
    final logs = gameState.chatLogs;
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;

    // 새로운 로그가 추가되면 스크롤을 내리고, 로딩 상태를 해제함
    if (logs.length != _prevLogCount) {
      _prevLogCount = logs.length;
      if (_isAwaitingReply && logs.isNotEmpty && logs.last.type == ChatLogType.aiReply) {
        // 프레임 렌더링 후 상태 변경 에러를 막기 위해 Future.microtask 사용
        Future.microtask(() {
          if (mounted) {
            setState(() {
              _isAwaitingReply = false;
              _pendingQuestion = null;
            });
          }
        });
      }
      _scrollToBottom();
    }

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: Material(
        color: Colors.transparent,
        child: Container(
          height: widget.height,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.97),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.14),
                blurRadius: 20,
                offset: const Offset(0, -8),
              ),
            ],
          ),
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                const SizedBox(height: 10),
                // 상단 핸들러
                Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                
                // 헤더 영역
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: const Color(0xFFDCFCE7),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.smart_toy_rounded,
                          color: Color(0xFF15803D),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'AI MOYA 채널',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF111827),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              logs.isEmpty
                                  ? '실시간으로 질문하고 힌트를 받을 수 있습니다.'
                                  : '진행 및 대화 로그 ${logs.length}개',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // ★ 로딩 인디케이터 배지
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: _isAwaitingReply ? const Color(0xFFDCFCE7) : const Color(0xFFE5E7EB),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          _isAwaitingReply ? '응답 대기' : '실시간',
                          style: TextStyle(
                            color: _isAwaitingReply ? const Color(0xFF15803D) : const Color(0xFF4B5563),
                            fontWeight: FontWeight.w700,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // 로그 리스트 영역
                Expanded(
                  child: logs.isEmpty
                      ? _EmptyAiLog(
                          isGhostMode: widget.isGhostMode,
                          onExampleTap: (text) {
                            _controller.text = text;
                            _sendMessage();
                          },
                        )
                      : ListView.separated(
                          controller: _scrollCtrl,
                          padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                          itemCount: logs.length + (_isAwaitingReply ? 1 : 0),
                          separatorBuilder: (_, __) => const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            if (index == logs.length && _isAwaitingReply) {
                              return _PendingAiQuestionCard(question: _pendingQuestion ?? '');
                            }
                            return _buildLogCard(logs[index]);
                          },
                        ),
                ),

                // 채팅 입력 영역
                Container(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
                  decoration: const BoxDecoration(
                    border: Border(
                      top: BorderSide(color: Color(0xFFE5E7EB)),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          enabled: !widget.isGhostMode && !_isAwaitingReply,
                          textInputAction: TextInputAction.send,
                          minLines: 1,
                          maxLines: 3,
                          onSubmitted: (_) => _sendMessage(),
                          decoration: InputDecoration(
                            hintText: widget.isGhostMode 
                                ? '유령 상태에서는 질문할 수 없습니다.' 
                                : 'AI MOYA에게 질문하기',
                            hintStyle: const TextStyle(color: Color(0xFF9CA3AF)),
                            filled: true,
                            fillColor: const Color(0xFFF3F4F6),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 12,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(18),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 48,
                        height: 48,
                        child: ElevatedButton(
                          onPressed: (widget.isGhostMode || _isAwaitingReply) ? null : _sendMessage,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF16A34A),
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: Colors.grey.shade300,
                            padding: EdgeInsets.zero,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          child: _isAwaitingReply 
                              ? const SizedBox(
                                  width: 20, height: 20, 
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)
                                )
                              : const Icon(Icons.send_rounded, size: 20),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ★ 일반 말풍선이 아닌, 게임 몰입감을 주는 카드 형태로 복원
  Widget _buildLogCard(ChatLog log) {
    final theme = _getThemeForLog(log.type);
    
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 왼쪽 컬러 띠
          Container(
            width: 4,
            decoration: BoxDecoration(
              color: theme.color,
              borderRadius: const BorderRadius.horizontal(left: Radius.circular(16)),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: theme.color.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(theme.icon, color: theme.color, size: 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          theme.label,
                          style: TextStyle(
                            color: theme.color,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          log.message,
                          style: const TextStyle(
                            fontSize: 14,
                            height: 1.45,
                            color: Color(0xFF111827),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  _LogTheme _getThemeForLog(ChatLogType type) {
    return switch (type) {
      ChatLogType.aiAnnounce => _LogTheme(
          label: '게임 진행', color: Colors.blue, icon: Icons.campaign_rounded),
      ChatLogType.aiReply => _LogTheme(
          label: 'AI MOYA', color: Colors.green, icon: Icons.smart_toy_rounded),
      ChatLogType.myQuestion => _LogTheme(
          label: '내 질문', color: Colors.deepPurple, icon: Icons.person_rounded),
      ChatLogType.system => _LogTheme(
          label: '시스템', color: Colors.redAccent, icon: Icons.info_outline_rounded),
    };
  }
}

class _LogTheme {
  final String label;
  final Color color;
  final IconData icon;
  _LogTheme({required this.label, required this.color, required this.icon});
}

// ★ 대기 중 카드 컴포넌트 복원
class _PendingAiQuestionCard extends StatelessWidget {
  const _PendingAiQuestionCard({required this.question});
  final String question;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FDF4),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFBBF7D0)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(
            width: 16, height: 16,
            child: CircularProgressIndicator(strokeWidth: 2.2, color: Color(0xFF16A34A)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'AI가 답변을 생성하고 있습니다...',
                  style: TextStyle(color: Color(0xFF166534), fontWeight: FontWeight.w700, fontSize: 12),
                ),
                const SizedBox(height: 4),
                Text(
                  question,
                  style: const TextStyle(color: Color(0xFF14532D), fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyAiLog extends StatelessWidget {
  const _EmptyAiLog({required this.onExampleTap, required this.isGhostMode});

  final ValueChanged<String> onExampleTap;
  final bool isGhostMode;

  @override
  Widget build(BuildContext context) {
    // LayoutBuilder로 실제 가용 높이를 측정해 overflow 방지
    // 키보드 노출 등으로 공간이 줄어들면 점진적으로 콘텐츠를 숨깁니다.
    return LayoutBuilder(
      builder: (context, constraints) {
        final h = constraints.maxHeight;
        // 단계별 임계값
        // < 60px : 텍스트 한 줄만 (최소 표시)
        // 60~130px: 아이콘 + 주요 텍스트 (설명 텍스트·칩 생략)
        // ≥ 130px : 전체 콘텐츠 표시
        final showIcon       = h >= 60;
        final showSubText    = h >= 130;
        final showChips      = h >= 130 && !isGhostMode;

        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showIcon) ...[
                  Icon(
                    isGhostMode ? Icons.visibility_rounded : Icons.forum_outlined,
                    size: 40,
                    color: const Color(0xFF9CA3AF),
                  ),
                  const SizedBox(height: 12),
                ],
                Text(
                  isGhostMode ? '유령 관전 모드입니다.' : 'AI MOYA와 대화를 시작해보세요.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                ),
                if (showSubText) ...[
                  const SizedBox(height: 6),
                  Text(
                    isGhostMode
                        ? '다른 플레이어들의 게임 진행 상황 로그만 볼 수 있습니다.'
                        : '예시 질문을 눌러 바로 힌트를 요청할 수 있습니다.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                  ),
                ],
                if (showChips) ...[
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      ActionChip(
                        onPressed: () => onExampleTap('지금 가장 중요한 단서가 뭐야?'),
                        backgroundColor: const Color(0xFFF3F4F6),
                        label: const Text('지금 중요한 단서'),
                      ),
                      ActionChip(
                        onPressed: () => onExampleTap('누가 가장 수상해 보여?'),
                        backgroundColor: const Color(0xFFF3F4F6),
                        label: const Text('수상한 사람 찾기'),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}