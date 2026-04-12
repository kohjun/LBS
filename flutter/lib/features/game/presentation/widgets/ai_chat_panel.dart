import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../game/data/game_models.dart';
import '../../../game/providers/game_provider.dart';

class AIChatPanel extends ConsumerStatefulWidget {
  const AIChatPanel({
    super.key,
    required this.sessionId,
    this.height = 236,
  });

  final String sessionId;
  final double height;

  @override
  ConsumerState<AIChatPanel> createState() => _AIChatPanelState();
}

class _AIChatPanelState extends ConsumerState<AIChatPanel> {
  final _controller = TextEditingController();
  final _scrollCtrl = ScrollController();
  int _prevLogCount = 0;

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
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    ref.read(gameProvider(widget.sessionId).notifier).askAI(text);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final gameState = ref.watch(gameProvider(widget.sessionId));
    final logs = gameState.chatLogs;
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;

    if (logs.length != _prevLogCount) {
      _prevLogCount = logs.length;
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
                Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
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
                              'AI MOYA',
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
                                  : '대화 ${logs.length}개',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: logs.isEmpty
                      ? _EmptyAiLog(
                          onExampleTap: (text) {
                            _controller.text = text;
                          },
                        )
                      : ListView.builder(
                          controller: _scrollCtrl,
                          padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                          itemCount: logs.length,
                          itemBuilder: (context, index) =>
                              _buildLogItem(logs[index]),
                        ),
                ),
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
                          textInputAction: TextInputAction.send,
                          minLines: 1,
                          maxLines: 3,
                          onSubmitted: (_) => _sendMessage(),
                          decoration: InputDecoration(
                            hintText: 'AI MOYA에게 질문하기',
                            hintStyle:
                                const TextStyle(color: Color(0xFF9CA3AF)),
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
                          onPressed: _sendMessage,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF16A34A),
                            foregroundColor: Colors.white,
                            padding: EdgeInsets.zero,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          child: const Icon(Icons.send_rounded, size: 20),
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

  Widget _buildLogItem(ChatLog log) {
    final isMine = log.type == ChatLogType.myQuestion;

    final backgroundColor = switch (log.type) {
      ChatLogType.aiAnnounce => const Color(0xFFEEF6FF),
      ChatLogType.aiReply => const Color(0xFFF0FDF4),
      ChatLogType.myQuestion => const Color(0xFFDBEAFE),
      ChatLogType.system => const Color(0xFFFFF7ED),
    };

    final textColor = switch (log.type) {
      ChatLogType.aiAnnounce => const Color(0xFF1D4ED8),
      ChatLogType.aiReply => const Color(0xFF166534),
      ChatLogType.myQuestion => const Color(0xFF1E3A8A),
      ChatLogType.system => const Color(0xFFC2410C),
    };

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 300),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: backgroundColor.withValues(alpha: 0.95),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _labelFor(log.type),
              style: TextStyle(
                color: textColor,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              log.message,
              style: const TextStyle(
                color: Color(0xFF111827),
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _labelFor(ChatLogType type) {
    return switch (type) {
      ChatLogType.aiAnnounce => '진행 메시지',
      ChatLogType.aiReply => 'AI MOYA',
      ChatLogType.myQuestion => '내 질문',
      ChatLogType.system => '시스템',
    };
  }
}

class _EmptyAiLog extends StatelessWidget {
  const _EmptyAiLog({required this.onExampleTap});

  final ValueChanged<String> onExampleTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.forum_outlined,
                    size: 34,
                    color: Color(0xFF9CA3AF),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'AI MOYA와 대화를 시작해보세요.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF111827),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '예시 질문을 눌러 바로 힌트를 요청할 수 있습니다.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.grey.shade600,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      _ExampleChip(
                        label: '지금 중요한 단서',
                        onTap: () => onExampleTap('지금 중요한 단서가 뭐야?'),
                      ),
                      _ExampleChip(
                        label: '수상한 사람',
                        onTap: () => onExampleTap('누가 가장 수상해 보여?'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ExampleChip extends StatelessWidget {
  const _ExampleChip({
    required this.label,
    required this.onTap,
  });

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      onPressed: onTap,
      backgroundColor: const Color(0xFFF3F4F6),
      labelStyle: const TextStyle(
        color: Color(0xFF374151),
        fontWeight: FontWeight.w600,
      ),
      label: Text(label),
    );
  }
}
