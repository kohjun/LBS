// lib/features/home/presentation/home_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../auth/data/auth_repository.dart';
import '../data/session_repository.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  // ── 이미 참여 중인 세션이 있는지 확인하는 헬퍼 메서드 ────────────────────────
  bool _hasActiveSession(BuildContext context, WidgetRef ref) {
    final sessions = ref.read(sessionListProvider).valueOrNull ?? [];
    if (sessions.isNotEmpty) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('입장 불가'),
          content: const Text('이미 참여 중인 세션이 있습니다. 기존 세션을 완전히 종료하거나 나간 후 새로운 세션에 참여해주세요.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('확인'),
            ),
          ],
        ),
      );
      return true; // 활성 세션 있음
    }
    return false; // 활성 세션 없음
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState    = ref.watch(authProvider);
    final sessionState = ref.watch(sessionListProvider);
    final user         = authState.valueOrNull;

    // 참여 중인 세션이 있는지 여부 (FAB 숨김 처리에 사용)
    final hasSession = (sessionState.valueOrNull?.isNotEmpty ?? false);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('내 세션', style: TextStyle(fontWeight: FontWeight.bold)),
            if (user != null)
              Text(
                user.nickname,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.normal),
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '새로고침',
            onPressed: () => ref.read(sessionListProvider.notifier).refresh(),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '설정',
            onPressed: () => context.push(AppRoutes.settings),
          ),
        ],
      ),

      body: sessionState.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorView(
          message: e.toString(),
          onRetry: () => ref.read(sessionListProvider.notifier).refresh(),
        ),
        data: (sessions) => sessions.isEmpty
            ? _EmptyView(
                onCreateSession: () => _showCreateDialog(context, ref),
                onJoinSession:   () => _showJoinDialog(context, ref),
              )
            : RefreshIndicator(
                onRefresh: () => ref.read(sessionListProvider.notifier).refresh(),
                child: ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: sessions.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, index) => _SessionCard(
                    session: sessions[index],
                    onTap: () {
                      final s = sessions[index];
                      if (s.gameStatus == 'playing') {
                        // 게임 진행 중인 세션은 맵으로 직접 이동
                        context.push('/map/${s.id}');
                      } else {
                        context.push(
                          '/lobby/${s.id}?sessionType=${s.sessionType.name}',
                        );
                      }
                    },
                    onLeave: () => _confirmLeave(context, ref, sessions[index]),
                  ),
                ),
              ),
      ),

      // 1인 1방 규칙: 세션이 이미 존재하면 플로팅 버튼 숨김
      floatingActionButton: hasSession 
          ? null 
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton.extended(
                  heroTag: 'join',
                  onPressed: () => _showJoinDialog(context, ref),
                  icon: const Icon(Icons.group_add),
                  label: const Text('코드로 참가'),
                  backgroundColor: Colors.white,
                  foregroundColor: const Color(0xFF2196F3),
                ),
                const SizedBox(height: 12),
                FloatingActionButton.extended(
                  heroTag: 'create',
                  onPressed: () => _showCreateDialog(context, ref),
                  icon: const Icon(Icons.add),
                  label: const Text('세션 생성'),
                ),
              ],
            ),
    );
  }

  // ── 세션 생성 다이얼로그 (유지 시간 선택 추가) ──────────────────────────────
  void _showCreateDialog(BuildContext context, WidgetRef ref) {
    if (_hasActiveSession(context, ref)) return;

    final ctrl = TextEditingController();
    int selectedHours = 1;
    double maxMembers = 3; // 최대 인원 기본값 3명
    SessionType selectedType = SessionType.defaultType;

    final Map<int, String> durationOptions = {
      1: '1시간 (기본)',
      6: '6시간',
      24: '24시간',
      72: '3일',
      120: '5일',
      168: '7일',
    };

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: const Text('새 세션 생성'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: ctrl,
                    autofocus: true,
                    maxLength: 30,
                    decoration: const InputDecoration(
                      labelText: '세션 이름',
                      hintText: '예: 가족 나들이',
                    ),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<int>(
                    initialValue: selectedHours,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '세션 유지 시간',
                    ),
                    items: durationOptions.entries.map((entry) {
                      return DropdownMenuItem<int>(
                        value: entry.key,
                        child: Text(entry.value),
                      );
                    }).toList(),
                    onChanged: (int? newValue) {
                      if (newValue != null) {
                        setDialogState(() {
                          selectedHours = newValue;
                        });
                      }
                    },
                  ),
                  const SizedBox(height: 24),
                  
                  // 최대 인원 설정
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('최대 인원', style: TextStyle(fontWeight: FontWeight.bold)),
                      Text(
                        '${maxMembers.toInt()}명',
                        style: const TextStyle(color: Colors.blue, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  Slider(
                    value: maxMembers,
                    min: 3,
                    max: 20,
                    divisions: 17, // 3부터 20까지 17칸
                    label: '${maxMembers.toInt()}명',
                    onChanged: (value) {
                      setDialogState(() {
                        maxMembers = value;
                      });
                    },
                  ),
                  const Text(
                    '최소 3명에서 최대 20명까지 설정할 수 있습니다.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 24),

                  // 세션 타입 선택
                  const Text('세션 타입', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _TypeCard(
                        icon: Icons.location_on,
                        label: '기본\n위치공유',
                        type: SessionType.defaultType,
                        selected: selectedType == SessionType.defaultType,
                        onTap: () => setDialogState(() => selectedType = SessionType.defaultType),
                      ),
                      const SizedBox(width: 8),
                      _TypeCard(
                        icon: Icons.directions_run,
                        label: '공간\n추격전',
                        type: SessionType.chase,
                        selected: selectedType == SessionType.chase,
                        onTap: () => setDialogState(() => selectedType = SessionType.chase),
                      ),
                      const SizedBox(width: 8),
                      _TypeCard(
                        icon: Icons.record_voice_over,
                        label: '언어\n추론',
                        type: SessionType.verbal,
                        selected: selectedType == SessionType.verbal,
                        onTap: () => setDialogState(() => selectedType = SessionType.verbal),
                      ),
                      const SizedBox(width: 8),
                      _TypeCard(
                        icon: Icons.explore,
                        label: '위치\n탐색',
                        type: SessionType.location,
                        selected: selectedType == SessionType.location,
                        onTap: () => setDialogState(() => selectedType = SessionType.location),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('취소'),
              ),
              ElevatedButton(
                onPressed: () async {
                  final name = ctrl.text.trim();
                  if (name.isEmpty) return;
                  Navigator.pop(ctx);

                  try {
                    final session = await ref.read(sessionListProvider.notifier).createSession(
                      name,
                      durationHours: selectedHours,
                      maxMembers: maxMembers.toInt(),
                      activeModules: selectedType.toModules(),
                    );

                    if (context.mounted) {
                      context.push(
                        '/lobby/${session.id}?sessionType=${selectedType.name}',
                      );
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('세션 생성 실패: $e'), backgroundColor: Colors.red),
                      );
                    }
                  }
                },
                child: const Text('생성'),
              ),
            ],
          );
        },
      ),
    );
  }

  // ── 초대 코드로 참가 다이얼로그 ──────────────────────────────────────────
  void _showJoinDialog(BuildContext context, WidgetRef ref) {
    if (_hasActiveSession(context, ref)) return;

    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('초대 코드로 참가'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[A-Z0-9a-z]')),
            LengthLimitingTextInputFormatter(8),
          ],
          decoration: const InputDecoration(
            labelText: '초대 코드',
            hintText: 'ABCD1234',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () async {
              final code = ctrl.text.trim().toUpperCase();
              if (code.isEmpty) return;
              Navigator.pop(ctx);
              try {
                final session = await ref.read(sessionListProvider.notifier).joinSession(code);
                if (context.mounted) {
                  context.push(
                    '/lobby/${session.id}?sessionType=${session.sessionType.name}',
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('참가 실패: $e'), backgroundColor: Colors.red),
                  );
                }
              }
            },
            child: const Text('참가'),
          ),
        ],
      ),
    );
  }

  // ── 로그아웃 확인 ─────────────────────────────────────────────────────────
  // ignore: unused_element
  void _confirmLogout(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('로그아웃'),
        content: const Text('로그아웃하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(authProvider.notifier).logout();
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: const Text('로그아웃'),
          ),
        ],
      ),
    );
  }

  // ── 세션 나가기 확인 ──────────────────────────────────────────────────────
  void _confirmLeave(BuildContext context, WidgetRef ref, Session session) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('세션 나가기'),
        content: Text('"${session.name}" 세션에서 나가시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await ref.read(sessionListProvider.notifier).leaveSession(session.id);
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('나가기 실패: $e'), backgroundColor: Colors.red),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: const Text('나가기'),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 세션 카드
// ─────────────────────────────────────────────────────────────────────────────

class _SessionCard extends StatefulWidget {
  const _SessionCard({
    required this.session,
    required this.onTap,
    required this.onLeave,
  });

  final Session session;
  final VoidCallback onTap;
  final VoidCallback onLeave;

  @override
  State<_SessionCard> createState() => _SessionCardState();
}

class _SessionCardState extends State<_SessionCard> {
  // 남은 시간을 계산하는 헬퍼 함수
  String _getRemainingTime(DateTime? expiresAt) {
    if (expiresAt == null) return '만료 시간 없음';
    
    final diff = expiresAt.difference(DateTime.now());
    if (diff.isNegative) return '만료됨';

    if (diff.inDays > 0) {
      return '${diff.inDays}일 ${diff.inHours % 24}시간 남음';
    } else if (diff.inHours > 0) {
      return '${diff.inHours}시간 ${diff.inMinutes % 60}분 남음';
    } else {
      return '${diff.inMinutes}분 남음';
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final remainingTimeText = _getRemainingTime(session.expiresAt);
    final isExpired = session.expiresAt != null && session.expiresAt!.isBefore(DateTime.now());

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        // ★ 수정됨: 만료된 방이면 탭(입장)을 막고 스낵바를 띄움
        onTap: isExpired 
            ? () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('만료된 세션입니다. 잠시 후 완전히 종료됩니다.'),
                    backgroundColor: Colors.grey,
                    duration: Duration(seconds: 2),
                  ),
                );
              }
            : widget.onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // 세션 아이콘 (기본 마커 아이콘)
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFF2196F3).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.location_on, color: Color(0xFF2196F3)),
                  ),
                  const SizedBox(width: 12),

                  // 세션 이름 + 뱃지 + 남은 시간
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                session.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (session.isHost)
                              Container(
                                margin: const EdgeInsets.only(left: 8),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF2196F3),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: const Text(
                                  '호스트',
                                  style: TextStyle(
                                      color: Colors.white, fontSize: 11),
                                ),
                              ),
                            Container(
                              margin: const EdgeInsets.only(left: 6),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: session.gameStatus == 'playing'
                                    ? Colors.green
                                    : Colors.orange,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                session.gameStatus == 'playing' ? '진행중' : '대기중',
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 11),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            // 인원수 표시
                            const Icon(Icons.people_outlined, size: 14, color: Colors.grey),
                            const SizedBox(width: 4),
                            Text(
                              '${session.memberCount}명',
                              style: TextStyle(color: Colors.grey[600], fontSize: 13),
                            ),
                            
                            const SizedBox(width: 12),
                            
                            // 남은 시간 표시 (만료되었으면 빨간색, 아니면 주황색)
                            Icon(
                              Icons.timer_outlined, 
                              size: 14, 
                              color: isExpired ? Colors.red : Colors.orange[700]
                            ),
                            const SizedBox(width: 4),
                            Text(
                              remainingTimeText,
                              style: TextStyle(
                                color: isExpired ? Colors.red : Colors.orange[700], 
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // 초대 코드 + 나가기 버튼
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (session.code.isNotEmpty)
                        GestureDetector(
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: session.code));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('코드가 복사되었습니다'),
                                duration: Duration(seconds: 1),
                              ),
                            );
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey[300]!),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  session.code,
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                const Icon(Icons.copy, size: 12, color: Colors.grey),
                              ],
                            ),
                          ),
                        ),
                      IconButton(
                        icon: const Icon(Icons.exit_to_app,
                            size: 20, color: Colors.red),
                        tooltip: '나가기',
                        onPressed: widget.onLeave,
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 세션 타입 선택 카드
// ─────────────────────────────────────────────────────────────────────────────

class _TypeCard extends StatelessWidget {
  const _TypeCard({
    required this.icon,
    required this.label,
    required this.type,
    required this.selected,
    required this.onTap,
  });

  final IconData      icon;
  final String        label;
  final SessionType   type;
  final bool          selected;
  final VoidCallback  onTap;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? color.withValues(alpha: 0.12) : Colors.grey[100],
            border: Border.all(
              color: selected ? color : Colors.grey[300]!,
              width: selected ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: selected ? color : Colors.grey[500], size: 24),
              const SizedBox(height: 4),
              Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                  color: selected ? color : Colors.grey[600],
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 빈 상태 뷰
// ─────────────────────────────────────────────────────────────────────────────

class _EmptyView extends StatelessWidget {
  const _EmptyView({
    required this.onCreateSession,
    required this.onJoinSession,
  });

  final VoidCallback onCreateSession;
  final VoidCallback onJoinSession;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.location_off, size: 80, color: Colors.grey[300]),
          const SizedBox(height: 16),
          Text(
            '참가 중인 세션이 없습니다',
            style: TextStyle(color: Colors.grey[600], fontSize: 16),
          ),
          const SizedBox(height: 32),
          OutlinedButton.icon(
            onPressed: onJoinSession,
            icon: const Icon(Icons.group_add),
            label: const Text('코드로 참가'),
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: onCreateSession,
            icon: const Icon(Icons.add),
            label: const Text('새 세션 만들기'),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 에러 뷰
// ─────────────────────────────────────────────────────────────────────────────

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String       message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 60, color: Colors.red),
          const SizedBox(height: 16),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('다시 시도'),
          ),
        ],
      ),
    );
  }
}
