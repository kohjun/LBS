// lib/features/game/presentation/session_info_screen.dart
//
// 세션 정보 화면
//  – SessionInfoContent : 재사용 가능한 컨텐츠 위젯
//                         (GameMainScreen 오버레이 & 독립 화면 모두에서 사용)
//  – SessionInfoScreen  : SessionInfoContent를 Scaffold로 감싼 독립 화면
//                         (GoRouter route용, 필요 시 직접 접근 가능)

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../home/data/session_repository.dart';
import '../data/game_models.dart';
import '../providers/game_provider.dart';

// ══════════════════════════════════════════════════════════════════════════════
// SessionInfoScreen – 독립 화면 래퍼 (GoRouter route용)
// ══════════════════════════════════════════════════════════════════════════════

class SessionInfoScreen extends ConsumerWidget {
  const SessionInfoScreen({
    super.key,
    required this.sessionId,
    required this.sessionType,
  });

  final String sessionId;
  final SessionType sessionType;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0A2A),
      body: SafeArea(
        child: SessionInfoContent(
          sessionId: sessionId,
          sessionType: sessionType,
          onClose: () => Navigator.of(context).maybePop(),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// SessionInfoContent – 재사용 가능한 컨텐츠 위젯
// GameMainScreen의 오버레이에서도, SessionInfoScreen에서도 사용합니다
// ══════════════════════════════════════════════════════════════════════════════

class SessionInfoContent extends ConsumerStatefulWidget {
  const SessionInfoContent({
    super.key,
    required this.sessionId,
    required this.sessionType,
    required this.onClose,
  });

  final String sessionId;
  final SessionType sessionType;
  final VoidCallback onClose;

  @override
  ConsumerState<SessionInfoContent> createState() => _SessionInfoContentState();
}

class _SessionInfoContentState extends ConsumerState<SessionInfoContent> {
  // 코인은 추후 Provider로 연동. 현재는 임시 값.
  int _coins = 0;

  // ── 미션 상세 모달 열기 ─────────────────────────────────────────────────────
  void _openMissionDetail(GameMission mission) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _MissionDetailSheet(
        mission: mission,
        sessionId: widget.sessionId,
      ),
    );
  }

  // ── 아이템 상점 모달 열기 ───────────────────────────────────────────────────
  void _openShop() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ItemShopSheet(coins: _coins),
    );
  }

  @override
  Widget build(BuildContext context) {
    final gameState = ref.watch(gameProvider(widget.sessionId));
    final sessionsAsync = ref.watch(sessionListProvider);
    final session = sessionsAsync.valueOrNull
        ?.where((s) => s.id == widget.sessionId)
        .firstOrNull;
    final myRole = gameState.myRole;

    // 미션 목록 – isFake가 아닌 것만 표시
    final missions = gameState.missions.where((m) => !m.isFake).toList();

    return Column(
      children: [
        // ── 헤더 ──────────────────────────────────────────────────────────
        _buildHeader(),
        // ── 스크롤 컨텐츠 ─────────────────────────────────────────────────
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (session != null) ...[
                  _buildSessionCard(session),
                  const SizedBox(height: 16),
                ],
                if (myRole != null) ...[
                  _buildRoleCard(myRole),
                  const SizedBox(height: 16),
                ],
                _buildMissionSection(missions),
                const SizedBox(height: 20),
                _buildShopButton(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── 헤더 ─────────────────────────────────────────────────────────────────
  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 8, 16, 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        border: Border(
            bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: widget.onClose,
            icon: const Icon(Icons.arrow_back_ios_new_rounded,
                color: Colors.white, size: 20),
            tooltip: '게임으로 돌아가기',
          ),
          const SizedBox(width: 2),
          const Text(
            '세션 정보',
            style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w700),
          ),
          const Spacer(),
          // 코인 배지
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF6DA),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.monetization_on_rounded,
                    color: Color(0xFFC58A00), size: 16),
                const SizedBox(width: 4),
                Text('$_coins',
                    style: const TextStyle(
                        color: Color(0xFFC58A00),
                        fontWeight: FontWeight.w700,
                        fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── 세션 카드 ─────────────────────────────────────────────────────────────
  Widget _buildSessionCard(Session session) {
    final typeLabel = _sessionTypeLabel(widget.sessionType);
    final remaining = session.expiresAt != null
        ? session.expiresAt!.difference(DateTime.now())
        : null;
    final remainStr = remaining != null && !remaining.isNegative
        ? '${remaining.inHours}h ${remaining.inMinutes.remainder(60)}m 남음'
        : null;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1E1B4B), Color(0xFF312E81)],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.meeting_room_rounded,
                  color: Colors.white70, size: 18),
              const SizedBox(width: 8),
              const Text('현재 세션',
                  style:
                      TextStyle(color: Colors.white60, fontSize: 13)),
              const Spacer(),
              if (remainStr != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(remainStr,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 11)),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(session.name,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _InfoChip(
                  label: '코드: ${session.code}',
                  icon: Icons.tag_rounded),
              _InfoChip(
                  label: '${session.memberCount}명',
                  icon: Icons.group_rounded),
              _InfoChip(
                  label: typeLabel,
                  icon: Icons.sports_esports_rounded),
            ],
          ),
        ],
      ),
    );
  }

  // ── 역할 카드 ─────────────────────────────────────────────────────────────
  Widget _buildRoleCard(GameRole role) {
    final isImpostor = role.isImpostor;
    final bg = isImpostor
        ? const LinearGradient(
            colors: [Color(0xFF7F1D1D), Color(0xFFB91C1C)])
        : const LinearGradient(
            colors: [Color(0xFF064E3B), Color(0xFF059669)]);
    final roleLabel = isImpostor ? '임포스터' : '크루원';
    final roleDesc = isImpostor
        ? '다른 플레이어를 제거하고 발각되지 마세요!'
        : '모든 미션을 완료하고 임포스터를 찾아내세요!';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: bg,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(
              isImpostor
                  ? Icons.sentiment_very_dissatisfied_rounded
                  : Icons.person_rounded,
              color: Colors.white,
              size: 28,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('내 역할: $roleLabel',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(roleDesc,
                    style: TextStyle(
                        color:
                            Colors.white.withValues(alpha: 0.8),
                        fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── 미션 섹션 ─────────────────────────────────────────────────────────────
  Widget _buildMissionSection(List<GameMission> missions) {
    final completedCount = missions.where((m) => m.isCompleted).length;
    final total = missions.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.assignment_rounded,
                color: Colors.white70, size: 18),
            const SizedBox(width: 8),
            const Text('미션 목록',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700)),
            const Spacer(),
            if (total > 0)
              Text('$completedCount / $total 완료',
                  style: const TextStyle(
                      color: Colors.white60, fontSize: 12)),
          ],
        ),
        if (total > 0) ...[
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: total > 0 ? completedCount / total : 0,
              minHeight: 6,
              backgroundColor:
                  Colors.white.withValues(alpha: 0.12),
              valueColor: const AlwaysStoppedAnimation<Color>(
                  Color(0xFF34D399)),
            ),
          ),
        ],
        const SizedBox(height: 12),
        if (missions.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Column(
              children: [
                Icon(Icons.hourglass_empty_rounded,
                    color: Colors.white38, size: 36),
                SizedBox(height: 8),
                Text('아직 미션이 없습니다',
                    style: TextStyle(
                        color: Colors.white54, fontSize: 14)),
                Text('게임 시작 후 미션이 배정됩니다',
                    style: TextStyle(
                        color: Colors.white38, fontSize: 12)),
              ],
            ),
          )
        else
          ...missions.map(
            (mission) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _MissionTile(
                mission: mission,
                onTap: () => _openMissionDetail(mission),
              ),
            ),
          ),
      ],
    );
  }

  // ── 아이템 상점 버튼 ────────────────────────────────────────────────────────
  Widget _buildShopButton() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _openShop,
        icon: const Icon(Icons.storefront_rounded),
        label: const Text('아이템 상점 열기',
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w700)),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF7C3AED),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18)),
          elevation: 0,
        ),
      ),
    );
  }

  String _sessionTypeLabel(SessionType type) {
    switch (type) {
      case SessionType.chase:
        return '공간 추격전';
      case SessionType.verbal:
        return '언어 추론';
      case SessionType.location:
        return '위치 탐색';
      default:
        return '기본';
    }
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// 미션 타일
// ══════════════════════════════════════════════════════════════════════════════

class _MissionTile extends StatelessWidget {
  const _MissionTile({required this.mission, required this.onTap});
  final GameMission mission;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDone = mission.isCompleted;
    final typeInfo = _missionTypeInfo(mission.type);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: isDone ? null : onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isDone
                ? Colors.white.withValues(alpha: 0.05)
                : Colors.white.withValues(alpha: 0.09),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDone
                  ? const Color(0xFF34D399).withValues(alpha: 0.4)
                  : Colors.white.withValues(alpha: 0.14),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: isDone
                      ? const Color(0xFF34D399)
                          .withValues(alpha: 0.2)
                      : typeInfo.color.withValues(alpha: 0.18),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isDone
                      ? Icons.check_circle_rounded
                      : typeInfo.icon,
                  color: isDone
                      ? const Color(0xFF34D399)
                      : typeInfo.color,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      mission.title.isNotEmpty
                          ? mission.title
                          : mission.id,
                      style: TextStyle(
                        color: isDone
                            ? Colors.white.withValues(alpha: 0.5)
                            : Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        decoration: isDone
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        if (mission.zone.isNotEmpty) ...[
                          const Icon(Icons.location_on_rounded,
                              color: Colors.white38, size: 12),
                          const SizedBox(width: 3),
                          Text(mission.zone,
                              style: const TextStyle(
                                  color: Colors.white38,
                                  fontSize: 11)),
                          const SizedBox(width: 8),
                        ],
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: typeInfo.color
                                .withValues(alpha: 0.2),
                            borderRadius:
                                BorderRadius.circular(999),
                          ),
                          child: Text(typeInfo.label,
                              style: TextStyle(
                                  color: typeInfo.color,
                                  fontSize: 10)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (isDone)
                const Text('완료',
                    style: TextStyle(
                        color: Color(0xFF34D399),
                        fontWeight: FontWeight.w700,
                        fontSize: 12))
              else
                const Icon(Icons.chevron_right_rounded,
                    color: Colors.white38, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  _MissionTypeInfo _missionTypeInfo(String type) {
    switch (type) {
      case 'qr_scan':
        return _MissionTypeInfo(
            icon: Icons.qr_code_scanner_rounded,
            label: 'QR 스캔',
            color: const Color(0xFF60A5FA));
      case 'nfc_scan':
        return _MissionTypeInfo(
            icon: Icons.nfc_rounded,
            label: 'NFC 태그',
            color: const Color(0xFFA78BFA));
      case 'mini_game':
        return _MissionTypeInfo(
            icon: Icons.sports_esports_rounded,
            label: '미니게임',
            color: const Color(0xFFFBBF24));
      case 'stay':
        return _MissionTypeInfo(
            icon: Icons.my_location_rounded,
            label: '위치 체류',
            color: const Color(0xFF34D399));
      default:
        return _MissionTypeInfo(
            icon: Icons.task_alt_rounded,
            label: '기타',
            color: const Color(0xFF94A3B8));
    }
  }
}

class _MissionTypeInfo {
  const _MissionTypeInfo(
      {required this.icon, required this.label, required this.color});
  final IconData icon;
  final String label;
  final Color color;
}

// ══════════════════════════════════════════════════════════════════════════════
// 미션 상세 바텀시트
// ══════════════════════════════════════════════════════════════════════════════

class _MissionDetailSheet extends ConsumerStatefulWidget {
  const _MissionDetailSheet({
    required this.mission,
    required this.sessionId,
  });
  final GameMission mission;
  final String sessionId;

  @override
  ConsumerState<_MissionDetailSheet> createState() =>
      _MissionDetailSheetState();
}

class _MissionDetailSheetState
    extends ConsumerState<_MissionDetailSheet> {
  bool _isCompleting = false;

  Timer? _nfcTimer;
  int _nfcCountdown = 0;
  bool _isNfcScanning = false;

  final _qrController = TextEditingController();

  @override
  void dispose() {
    _nfcTimer?.cancel();
    _qrController.dispose();
    super.dispose();
  }

  Future<void> _completeMission() async {
    setState(() => _isCompleting = true);
    try {
      ref
          .read(gameProvider(widget.sessionId).notifier)
          .completeMission(widget.mission.id);
      await Future.delayed(const Duration(milliseconds: 600));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('미션 완료 처리 실패: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isCompleting = false);
    }
  }

  void _startNfcScan() {
    // TODO: nfc_manager 패키지 연동 후 실제 NFC 리딩으로 교체
    setState(() {
      _isNfcScanning = true;
      _nfcCountdown = 10;
    });
    _nfcTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _nfcCountdown--);
      if (_nfcCountdown <= 0) {
        timer.cancel();
        setState(() => _isNfcScanning = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content:
                  Text('NFC 태그를 찾지 못했습니다. 다시 시도하세요.')),
        );
      }
    });
  }

  void _stopNfcScan() {
    _nfcTimer?.cancel();
    setState(() => _isNfcScanning = false);
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.65,
      minChildSize: 0.45,
      maxChildSize: 0.92,
      builder: (ctx, scrollCtrl) {
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF0F172A), Color(0xFF1E1B4B)],
            ),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border.all(
                color: Colors.white.withValues(alpha: 0.1)),
          ),
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              controller: scrollCtrl,
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 44,
                      height: 4,
                      decoration: BoxDecoration(
                        color:
                            Colors.white.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  _buildMissionHeader(),
                  const SizedBox(height: 20),
                  _buildCompletionMethod(),
                  const SizedBox(height: 24),
                  if (!widget.mission.isCompleted)
                    _buildActionArea()
                  else
                    _buildCompletedBadge(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildMissionHeader() {
    final typeData = _typeData(widget.mission.type);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            color: typeData.color.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(16),
          ),
          child:
              Icon(typeData.icon, color: typeData.color, size: 28),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: typeData.color.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(typeData.label,
                    style: TextStyle(
                        color: typeData.color,
                        fontSize: 11,
                        fontWeight: FontWeight.w700)),
              ),
              const SizedBox(height: 6),
              Text(
                widget.mission.title.isNotEmpty
                    ? widget.mission.title
                    : widget.mission.id,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800),
              ),
              if (widget.mission.zone.isNotEmpty) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(Icons.location_on_rounded,
                        color: Colors.white54, size: 14),
                    const SizedBox(width: 4),
                    Text(widget.mission.zone,
                        style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 13)),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCompletionMethod() {
    switch (widget.mission.type) {
      case 'qr_scan':
        return _buildQrSection();
      case 'nfc_scan':
        return _buildNfcSection();
      case 'stay':
        return _buildStaySection();
      case 'mini_game':
        return _buildMiniGameSection();
      default:
        return _buildDefaultSection();
    }
  }

  Widget _buildQrSection() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF60A5FA).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
            color: const Color(0xFF60A5FA).withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.qr_code_scanner_rounded,
                  color: Color(0xFF60A5FA), size: 20),
              SizedBox(width: 8),
              Text('QR 코드 스캔',
                  style: TextStyle(
                      color: Color(0xFF60A5FA),
                      fontWeight: FontWeight.w700,
                      fontSize: 15)),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '미션 장소에서 QR 코드를 찾아 카메라로 스캔하세요.\n'
            'QR 코드에는 미션 완료를 위한 단서나 코드가 포함되어 있습니다.',
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.75),
                fontSize: 13,
                height: 1.5),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _showQrManualInput,
              icon: const Icon(Icons.camera_alt_rounded),
              label: const Text('QR 코드 스캔하기'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF60A5FA),
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showQrManualInput() {
    // TODO: mobile_scanner 패키지 추가 후 카메라 QR 스캔으로 교체
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1B4B),
        title: const Text('QR 코드 입력',
            style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'QR 코드를 스캔하거나 코드를 수동으로 입력하세요.',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 13),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _qrController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: '예: MISSION-ABC123',
                hintStyle: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4)),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.08),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소',
                style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              if (_qrController.text.trim().isNotEmpty) {
                _completeMission();
              }
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF60A5FA)),
            child: const Text('확인',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _buildNfcSection() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFA78BFA).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
            color: const Color(0xFFA78BFA).withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.nfc_rounded,
                  color: Color(0xFFA78BFA), size: 20),
              SizedBox(width: 8),
              Text('NFC 태그 스캔',
                  style: TextStyle(
                      color: Color(0xFFA78BFA),
                      fontWeight: FontWeight.w700,
                      fontSize: 15)),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '지정된 장소에 있는 NFC 태그에 스마트폰을 가까이 대세요.\n'
            '기기 뒷면(카메라 근처)을 태그에 약 2~3cm 가져다 대면 자동으로 인식됩니다.',
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.75),
                fontSize: 13,
                height: 1.5),
          ),
          const SizedBox(height: 14),
          if (_isNfcScanning) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFA78BFA)
                    .withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                        color: Color(0xFFA78BFA),
                        strokeWidth: 2.5),
                  ),
                  const SizedBox(width: 12),
                  Text(
                      'NFC 태그를 기다리는 중... ${_nfcCountdown}s',
                      style: const TextStyle(
                          color: Color(0xFFA78BFA),
                          fontWeight: FontWeight.w600)),
                  const Spacer(),
                  GestureDetector(
                    onTap: _stopNfcScan,
                    child: const Icon(Icons.close,
                        color: Colors.white38, size: 20),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isNfcScanning ? null : _startNfcScan,
              icon: const Icon(Icons.nfc_rounded),
              label: Text(
                  _isNfcScanning ? 'NFC 스캔 중...' : 'NFC 스캔 시작'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFA78BFA),
                foregroundColor: Colors.white,
                disabledBackgroundColor:
                    const Color(0xFFA78BFA).withValues(alpha: 0.4),
                padding:
                    const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: _completeMission,
              style: TextButton.styleFrom(
                foregroundColor: Colors.white38,
                padding:
                    const EdgeInsets.symmetric(vertical: 10),
              ),
              child: const Text('테스트: 완료 처리 (개발 중)',
                  style: TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStaySection() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF34D399).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
            color: const Color(0xFF34D399).withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.my_location_rounded,
                  color: Color(0xFF34D399), size: 20),
              SizedBox(width: 8),
              Text('위치 체류 미션',
                  style: TextStyle(
                      color: Color(0xFF34D399),
                      fontWeight: FontWeight.w700,
                      fontSize: 15)),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '지정된 구역에 이동하여 일정 시간 머무르세요.\n'
            '위치가 인식되면 자동으로 완료 처리됩니다.',
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.75),
                fontSize: 13,
                height: 1.5),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.location_on_rounded,
                  color: Colors.white38, size: 14),
              const SizedBox(width: 4),
              Text(
                  '목표 구역: ${widget.mission.zone.isNotEmpty ? widget.mission.zone : "서버에서 지정"}',
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMiniGameSection() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFFBBF24).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
            color: const Color(0xFFFBBF24).withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.sports_esports_rounded,
                  color: Color(0xFFFBBF24), size: 20),
              SizedBox(width: 8),
              Text('미니게임 미션',
                  style: TextStyle(
                      color: Color(0xFFFBBF24),
                      fontWeight: FontWeight.w700,
                      fontSize: 15)),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '주어진 미니게임을 클리어하면 미션이 완료됩니다.',
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.75),
                fontSize: 13),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _completeMission,
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('미니게임 시작'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFBBF24),
                foregroundColor: Colors.black87,
                padding:
                    const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDefaultSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        '게임 마스터의 안내에 따라 미션을 수행하세요.',
        style: TextStyle(
            color: Colors.white.withValues(alpha: 0.75),
            fontSize: 13),
      ),
    );
  }

  Widget _buildActionArea() {
    if (widget.mission.type == 'stay') {
      return Column(
        children: [
          const Divider(color: Colors.white12),
          const SizedBox(height: 12),
          Text(
            '위치가 자동으로 인식됩니다.\n해당 구역으로 이동하면 앱이 자동으로 완료 처리합니다.',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 12),
          ),
        ],
      );
    }
    if (widget.mission.type == 'qr_scan' ||
        widget.mission.type == 'nfc_scan') {
      return const SizedBox.shrink();
    }
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _isCompleting ? null : _completeMission,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF34D399),
          foregroundColor: Colors.black87,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16)),
        ),
        child: _isCompleting
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    color: Colors.black54, strokeWidth: 2))
            : const Text('미션 완료',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w800)),
      ),
    );
  }

  Widget _buildCompletedBadge() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF34D399).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: const Color(0xFF34D399).withValues(alpha: 0.4)),
      ),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.check_circle_rounded,
              color: Color(0xFF34D399), size: 22),
          SizedBox(width: 8),
          Text('이 미션은 이미 완료되었습니다!',
              style: TextStyle(
                  color: Color(0xFF34D399),
                  fontWeight: FontWeight.w700,
                  fontSize: 15)),
        ],
      ),
    );
  }

  _MissionTypeInfo _typeData(String type) {
    switch (type) {
      case 'qr_scan':
        return _MissionTypeInfo(
            icon: Icons.qr_code_scanner_rounded,
            label: 'QR 스캔',
            color: const Color(0xFF60A5FA));
      case 'nfc_scan':
        return _MissionTypeInfo(
            icon: Icons.nfc_rounded,
            label: 'NFC 태그',
            color: const Color(0xFFA78BFA));
      case 'mini_game':
        return _MissionTypeInfo(
            icon: Icons.sports_esports_rounded,
            label: '미니게임',
            color: const Color(0xFFFBBF24));
      case 'stay':
        return _MissionTypeInfo(
            icon: Icons.my_location_rounded,
            label: '위치 체류',
            color: const Color(0xFF34D399));
      default:
        return _MissionTypeInfo(
            icon: Icons.task_alt_rounded,
            label: '기타',
            color: const Color(0xFF94A3B8));
    }
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// 아이템 상점 바텀시트
// ══════════════════════════════════════════════════════════════════════════════

class _ItemShopSheet extends StatefulWidget {
  const _ItemShopSheet({required this.coins});
  final int coins;

  @override
  State<_ItemShopSheet> createState() => _ItemShopSheetState();
}

class _ItemShopSheetState extends State<_ItemShopSheet> {
  late int _coins;

  static const _items = [
    _ShopItemData(
        name: '이동속도 증가',
        desc: '30초간 이동 속도 +50%',
        price: 50,
        icon: Icons.speed_rounded),
    _ShopItemData(
        name: '시야 확장',
        desc: '60초간 시야 범위 +100%',
        price: 80,
        icon: Icons.visibility_rounded),
    _ShopItemData(
        name: '위치 은폐',
        desc: '30초간 위치 추적 불가',
        price: 100,
        icon: Icons.location_off_rounded),
    _ShopItemData(
        name: '순간이동',
        desc: '임의 위치로 순간이동',
        price: 150,
        icon: Icons.flash_on_rounded),
    _ShopItemData(
        name: '함정 설치',
        desc: '이동 경로에 함정 배치',
        price: 120,
        icon: Icons.pest_control_rounded),
    _ShopItemData(
        name: '쿨타임 감소',
        desc: '킬 쿨타임 -50% (1회)',
        price: 200,
        icon: Icons.timer_off_rounded),
  ];

  @override
  void initState() {
    super.initState();
    _coins = widget.coins;
  }

  void _buyItem(_ShopItemData item) {
    if (_coins < item.price) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('코인이 부족합니다.'),
            backgroundColor: Colors.redAccent,
            duration: Duration(seconds: 2)),
      );
      return;
    }
    // TODO: 서버로 구매 요청 전송
    setState(() => _coins -= item.price);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text('${item.name} 아이템을 구매했습니다!'),
          backgroundColor: const Color(0xFF7C3AED),
          duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      builder: (ctx, scrollCtrl) {
        return DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF1E1B4B), Color(0xFF312E81)],
            ),
            borderRadius:
                BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                Padding(
                  padding:
                      const EdgeInsets.fromLTRB(20, 16, 20, 12),
                  child: Row(
                    children: [
                      const Icon(Icons.storefront_rounded,
                          color: Colors.white, size: 22),
                      const SizedBox(width: 10),
                      const Text('아이템 상점',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w700)),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF6DA),
                          borderRadius:
                              BorderRadius.circular(999),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                                Icons.monetization_on_rounded,
                                color: Color(0xFFC58A00),
                                size: 16),
                            const SizedBox(width: 4),
                            Text('$_coins',
                                style: const TextStyle(
                                    color: Color(0xFFC58A00),
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: GridView.builder(
                    controller: scrollCtrl,
                    padding: const EdgeInsets.fromLTRB(
                        16, 0, 16, 20),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      childAspectRatio: 1.25,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                    ),
                    itemCount: _items.length,
                    itemBuilder: (context, i) {
                      final item = _items[i];
                      final canAfford = _coins >= item.price;
                      return Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white
                              .withValues(alpha: 0.08),
                          borderRadius:
                              BorderRadius.circular(16),
                          border: Border.all(
                              color: Colors.white
                                  .withValues(alpha: 0.12)),
                        ),
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            Icon(item.icon,
                                color: Colors.cyanAccent,
                                size: 26),
                            const SizedBox(height: 6),
                            Text(item.name,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13)),
                            const SizedBox(height: 2),
                            Expanded(
                              child: Text(item.desc,
                                  style: TextStyle(
                                      color: Colors.white
                                          .withValues(
                                              alpha: 0.6),
                                      fontSize: 11),
                                  maxLines: 2,
                                  overflow:
                                      TextOverflow.ellipsis),
                            ),
                            Row(
                              children: [
                                const Icon(
                                    Icons
                                        .monetization_on_rounded,
                                    color: Color(0xFFC58A00),
                                    size: 13),
                                const SizedBox(width: 3),
                                Text('${item.price}',
                                    style: const TextStyle(
                                        color:
                                            Color(0xFFC58A00),
                                        fontWeight:
                                            FontWeight.w700,
                                        fontSize: 12)),
                                const Spacer(),
                                GestureDetector(
                                  onTap: canAfford
                                      ? () => _buyItem(item)
                                      : null,
                                  child: Container(
                                    padding:
                                        const EdgeInsets
                                            .symmetric(
                                            horizontal: 10,
                                            vertical: 4),
                                    decoration: BoxDecoration(
                                      color: canAfford
                                          ? const Color(
                                              0xFF7C3AED)
                                          : Colors
                                              .grey.shade700,
                                      borderRadius:
                                          BorderRadius.circular(
                                              999),
                                    ),
                                    child: Text(
                                      canAfford ? '구매' : '부족',
                                      style: TextStyle(
                                          color: canAfford
                                              ? Colors.white
                                              : Colors.white54,
                                          fontSize: 11,
                                          fontWeight:
                                              FontWeight.w700),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ShopItemData {
  const _ShopItemData(
      {required this.name,
      required this.desc,
      required this.price,
      required this.icon});
  final String name;
  final String desc;
  final int price;
  final IconData icon;
}

// ── 공용 위젯 ──────────────────────────────────────────────────────────────────
class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.label, required this.icon});
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white60, size: 12),
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(
                  color: Colors.white70, fontSize: 11)),
        ],
      ),
    );
  }
}
