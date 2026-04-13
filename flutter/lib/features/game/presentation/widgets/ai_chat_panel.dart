import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../game/data/game_models.dart';
import '../../../game/providers/game_provider.dart';

class AIChatPanel extends ConsumerStatefulWidget {
  const AIChatPanel({
    super.key,
    required this.sessionId,
    this.isGhostMode = false,
    this.height = double.infinity,
    this.onDragUpdate,
    this.onDragEnd,
    this.onHandleTap,
    this.handleLabel,
  });

  final String sessionId;
  final bool isGhostMode;
  final double height;
  final GestureDragUpdateCallback? onDragUpdate;
  final GestureDragEndCallback? onDragEnd;
  final VoidCallback? onHandleTap;
  final String? handleLabel;

  @override
  ConsumerState<AIChatPanel> createState() => _AIChatPanelState();
}

class _AIChatPanelState extends ConsumerState<AIChatPanel> {
  final _controller = TextEditingController();
  final _scrollCtrl = ScrollController();

  bool _isAwaitingReply = false;
  String? _pendingQuestion;

  bool get _hasInteractiveHandle =>
      widget.onDragUpdate != null ||
      widget.onDragEnd != null ||
      widget.onHandleTap != null;

  @override
  void dispose() {
    _controller.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _scrollToBottom({int retryCount = 0}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollCtrl.hasClients) return;

      final position = _scrollCtrl.position;
      if (!position.hasPixels || !position.hasContentDimensions) {
        if (retryCount < 4) {
          _scrollToBottom(retryCount: retryCount + 1);
        }
        return;
      }

      final targetOffset = position.maxScrollExtent;
      if (!targetOffset.isFinite) return;
      if ((targetOffset - position.pixels).abs() < 1) return;

      _scrollCtrl
          .animateTo(
            targetOffset,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
          )
          .catchError((_) {});
    });
  }

  void _sendMessage() {
    if (widget.isGhostMode || _isAwaitingReply) return;

    final text = _controller.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _isAwaitingReply = true;
      _pendingQuestion = text;
    });

    ref.read(gameProvider(widget.sessionId).notifier).askAI(text);
    _controller.clear();
    _scrollToBottom();
  }

  void _handleLogsChanged(List<ChatLog> logs) {
    if (_isAwaitingReply && logs.isNotEmpty) {
      final lastType = logs.last.type;
      if (lastType == ChatLogType.aiReply || lastType == ChatLogType.system) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() {
            _isAwaitingReply = false;
            _pendingQuestion = null;
          });
          _scrollToBottom();
        });
        return;
      }
    }

    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AmongUsGameState>(
      gameProvider(widget.sessionId),
      (previous, next) {
        final previousCount = previous?.chatLogs.length ?? 0;
        if (previousCount == next.chatLogs.length) return;
        _handleLogsChanged(next.chatLogs);
      },
    );

    final gameState = ref.watch(gameProvider(widget.sessionId));
    final logs = gameState.chatLogs;
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;

    final panelBody = DecoratedBox(
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
            GestureDetector(
              onVerticalDragUpdate: widget.onDragUpdate,
              onVerticalDragEnd: widget.onDragEnd,
              onTap: widget.onHandleTap,
              behavior: HitTestBehavior.opaque,
              child: SizedBox(
                width: double.infinity,
                child: Column(
                  children: [
                    const SizedBox(height: 10),
                    Container(
                      width: 42,
                      height: 4,
                      decoration: BoxDecoration(
                        color: _hasInteractiveHandle
                            ? Colors.grey.shade400
                            : Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    if (widget.handleLabel != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        widget.handleLabel!,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: _hasInteractiveHandle
                              ? const Color(0xFF4B5563)
                              : const Color(0xFF9CA3AF),
                        ),
                      ),
                    ],
                    const SizedBox(height: 4),
                  ],
                ),
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
                          'AI MOYA Chat',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF111827),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          logs.isEmpty
                              ? 'Ask about the current game at any time.'
                              : '${logs.length} chat logs available.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: _isAwaitingReply
                          ? const Color(0xFFDCFCE7)
                          : const Color(0xFFE5E7EB),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      _isAwaitingReply ? 'Waiting' : 'Ready',
                      style: TextStyle(
                        color: _isAwaitingReply
                            ? const Color(0xFF15803D)
                            : const Color(0xFF4B5563),
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ),
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
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      itemCount: logs.length + (_isAwaitingReply ? 1 : 0),
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        if (index == logs.length && _isAwaitingReply) {
                          return _PendingAiQuestionCard(
                            question: _pendingQuestion ?? '',
                          );
                        }
                        return _buildLogCard(logs[index]);
                      },
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
                      enabled: !widget.isGhostMode && !_isAwaitingReply,
                      textInputAction: TextInputAction.send,
                      minLines: 1,
                      maxLines: 3,
                      onSubmitted: (_) => _sendMessage(),
                      decoration: InputDecoration(
                        hintText: widget.isGhostMode
                            ? 'Ghost mode cannot send AI questions.'
                            : 'Ask AI MOYA something',
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
                      onPressed: (widget.isGhostMode || _isAwaitingReply)
                          ? null
                          : _sendMessage,
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
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
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
    );

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: Material(
        color: Colors.transparent,
        child: widget.height.isFinite
            ? AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                height: widget.height,
                child: panelBody,
              )
            : SizedBox.expand(child: panelBody),
      ),
    );
  }

  Widget _buildLogCard(ChatLog log) {
    final theme = _getThemeForLog(log.type);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border(left: BorderSide(color: theme.color, width: 4)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
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
    );
  }

  _LogTheme _getThemeForLog(ChatLogType type) {
    return switch (type) {
      ChatLogType.aiAnnounce => const _LogTheme(
          label: 'Game Flow',
          color: Colors.blue,
          icon: Icons.campaign_rounded,
        ),
      ChatLogType.aiReply => const _LogTheme(
          label: 'AI MOYA',
          color: Colors.green,
          icon: Icons.smart_toy_rounded,
        ),
      ChatLogType.myQuestion => const _LogTheme(
          label: 'You',
          color: Colors.deepPurple,
          icon: Icons.person_rounded,
        ),
      ChatLogType.system => const _LogTheme(
          label: 'System',
          color: Colors.redAccent,
          icon: Icons.info_outline_rounded,
        ),
    };
  }
}

class _LogTheme {
  const _LogTheme({
    required this.label,
    required this.color,
    required this.icon,
  });

  final String label;
  final Color color;
  final IconData icon;
}

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
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              color: Color(0xFF16A34A),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'AI is preparing an answer...',
                  style: TextStyle(
                    color: Color(0xFF166534),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  question,
                  style: const TextStyle(
                    color: Color(0xFF14532D),
                    fontSize: 13,
                  ),
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
  const _EmptyAiLog({
    required this.onExampleTap,
    required this.isGhostMode,
  });

  final ValueChanged<String> onExampleTap;
  final bool isGhostMode;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final showIcon = height >= 60;
        final showSubText = height >= 130;
        final showChips = height >= 130 && !isGhostMode;

        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showIcon) ...[
                  Icon(
                    isGhostMode
                        ? Icons.visibility_rounded
                        : Icons.forum_outlined,
                    size: 40,
                    color: const Color(0xFF9CA3AF),
                  ),
                  const SizedBox(height: 12),
                ],
                Text(
                  isGhostMode
                      ? 'Ghost mode is active.'
                      : 'Start chatting with AI MOYA.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
                if (showSubText) ...[
                  const SizedBox(height: 6),
                  Text(
                    isGhostMode
                        ? 'You can only read game logs in ghost mode.'
                        : 'Ask for hints, priorities, or suspicious clues.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.grey.shade600,
                      fontSize: 13,
                    ),
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
                        onPressed: () => onExampleTap(
                          'What should I focus on right now?',
                        ),
                        backgroundColor: const Color(0xFFF3F4F6),
                        label: const Text('Current priority'),
                      ),
                      ActionChip(
                        onPressed: () => onExampleTap(
                          'What clue looks the most suspicious?',
                        ),
                        backgroundColor: const Color(0xFFF3F4F6),
                        label: const Text('Suspicious clue'),
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
