// lib/features/history/presentation/history_screen.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:intl/intl.dart';

import '../../../core/services/app_initialization_service.dart';
import '../data/history_repository.dart';
import '../../home/data/session_repository.dart';
import '../../auth/data/auth_repository.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 날짜 범위 preset
// ─────────────────────────────────────────────────────────────────────────────
enum DatePreset { today, week, custom }

// ─────────────────────────────────────────────────────────────────────────────
// HistoryScreen
// ─────────────────────────────────────────────────────────────────────────────
class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key, required this.sessionId});
  final String sessionId;

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen>
    with SingleTickerProviderStateMixin {
  // ── 상태 ──────────────────────────────────────────────────────────────────
  List<SessionMember> _members = [];
  String? _selectedUserId;

  DatePreset _preset = DatePreset.today;
  DateTime _from = _startOfDay(DateTime.now());
  DateTime _to   = DateTime.now();

  List<TrackPoint> _track = [];
  bool _loading = false;
  bool _mapSdkReady = false;

  NaverMapController? _mapCtrl;

  // ── 재생 ──────────────────────────────────────────────────────────────────
  bool _playing = false;
  int  _playIndex = 0;
  Timer? _playTimer;
  late AnimationController _animCtrl;

  static DateTime _startOfDay(DateTime d) =>
      DateTime(d.year, d.month, d.day);

  // ─────────────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    unawaited(_ensureMapSdkReady());
    _loadMembers();
  }

  Future<void> _ensureMapSdkReady() async {
    try {
      await AppInitializationService().ensureNaverMapInitialized();
      if (!mounted) return;
      setState(() => _mapSdkReady = true);
    } catch (e) {
      _showError('지도 초기화 실패: $e');
    }
  }

  @override
  void dispose() {
    _playTimer?.cancel();
    _animCtrl.dispose();
    _mapCtrl?.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _loadMembers() async {
    try {
      final session = await ref
          .read(sessionRepositoryProvider)
          .getSession(widget.sessionId);
      if (!mounted) return;
      final myId = ref.read(authProvider).valueOrNull?.id;
      setState(() {
        _members = session.members;
        _selectedUserId = _members
                .where((m) => m.userId == myId)
                .firstOrNull
                ?.userId ??
            _members.firstOrNull?.userId;
      });
      if (_selectedUserId != null) await _loadTrack();
    } catch (e) {
      _showError('멤버 목록 로드 실패: $e');
    }
  }

  Future<void> _loadTrack() async {
    if (_selectedUserId == null) return;
    setState(() { _loading = true; _track = []; });
    _stopPlay();

    try {
      final points = await ref.read(historyRepositoryProvider).getTrackHistory(
            widget.sessionId,
            _selectedUserId!,
            from: _from,
            to:   _to,
          );
      if (!mounted) return;
      setState(() { _track = points; _loading = false; });
      _updateOverlays();
      _fitPolyline();
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      _showError('경로 로드 실패: $e');
    }
  }

  // ── 오버레이 업데이트 (경로선 및 마커) ──────────────────────────────────────
  void _updateOverlays() {
    if (_mapCtrl == null) return;
    _mapCtrl!.clearOverlays();

    if (_track.isEmpty) return;

    final overlays = <NAddableOverlay>{};
    final points = _track.map((p) => NLatLng(p.lat, p.lng)).toList();

    if (points.length >= 2) {
      overlays.add(NPolylineOverlay(
        id: 'track_line',
        coords: points,
        color: const Color(0xFF2196F3),
        width: 4,
        lineCap: NLineCap.round,
        lineJoin: NLineJoin.round,
      ));
    }

    final p = _track[_playing ? _playIndex : _track.length - 1];
    overlays.add(NMarker(
      id: 'playhead',
      position: NLatLng(p.lat, p.lng),
    )
      ..setCaption(NOverlayCaption(text: _selectedNickname()))
      ..setSubCaption(NOverlayCaption(text: _formatTime(p.recordedAt))));

    _mapCtrl!.addOverlayAll(overlays);
  }

  // ── 지도 범위 조정 ─────────────────────────────────────────────────────────
  void _fitPolyline() {
    if (_track.isEmpty || _mapCtrl == null) return;
    var minLat = _track.first.lat, maxLat = _track.first.lat;
    var minLng = _track.first.lng, maxLng = _track.first.lng;
    for (final p in _track) {
      if (p.lat < minLat) minLat = p.lat;
      if (p.lat > maxLat) maxLat = p.lat;
      if (p.lng < minLng) minLng = p.lng;
      if (p.lng > maxLng) maxLng = p.lng;
    }

    final bounds = NLatLngBounds(
      southWest: NLatLng(minLat, minLng),
      northEast: NLatLng(maxLat, maxLng),
    );

    _mapCtrl!.updateCamera(
      NCameraUpdate.fitBounds(bounds, padding: const EdgeInsets.all(60))
        ..setAnimation(animation: NCameraAnimation.easing),
    );
  }

  // ── 경로 재생 ──────────────────────────────────────────────────────────────
  void _togglePlay() {
    if (_track.isEmpty) return;
    if (_playing) {
      _stopPlay();
    } else {
      _startPlay();
    }
  }

  void _startPlay() {
    setState(() { _playing = true; _playIndex = 0; });
    _playTimer = Timer.periodic(const Duration(milliseconds: 300), (t) {
      if (!mounted) { t.cancel(); return; }
      if (_playIndex >= _track.length - 1) {
        _stopPlay();
        return;
      }
      setState(() => _playIndex++);
      _updateOverlays();
      
      final p = _track[_playIndex];
      _mapCtrl?.updateCamera(
        NCameraUpdate.scrollAndZoomTo(target: NLatLng(p.lat, p.lng))
          ..setAnimation(animation: NCameraAnimation.linear),
      );
    });
  }

  void _stopPlay() {
    _playTimer?.cancel();
    if (mounted) {
      setState(() => _playing = false);
      _updateOverlays();
    }
  }

  // ── 날짜 preset 변경 ───────────────────────────────────────────────────────
  void _setPreset(DatePreset preset) async {
    if (preset == DatePreset.custom) {
      final range = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2024),
        lastDate: DateTime.now(),
        initialDateRange: DateTimeRange(start: _from, end: _to),
      );
      if (range == null) return;
      setState(() {
        _preset = DatePreset.custom;
        _from   = range.start;
        _to     = range.end.add(const Duration(hours: 23, minutes: 59));
      });
    } else {
      final now = DateTime.now();
      setState(() {
        _preset = preset;
        _from   = preset == DatePreset.today
            ? _startOfDay(now)
            : now.subtract(const Duration(days: 7));
        _to     = now;
      });
    }
    await _loadTrack();
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('위치 기록'),
        actions: [
          if (_track.isNotEmpty)
            IconButton(
              icon: Icon(_playing ? Icons.stop : Icons.play_arrow),
              tooltip: _playing ? '정지' : '경로 재생',
              onPressed: _togglePlay,
            ),
        ],
      ),
      body: Column(
        children: [
          // ── 필터 패널 ──────────────────────────────────────────────────
          _FilterPanel(
            members:          _members,
            selectedUserId:   _selectedUserId,
            preset:           _preset,
            from:             _from,
            to:               _to,
            onMemberChanged:  (id) {
              setState(() => _selectedUserId = id);
              _loadTrack();
            },
            onPresetChanged:  _setPreset,
          ),

          // ── 지도 ───────────────────────────────────────────────────────
          Expanded(
            flex: 5,
            child: Stack(
              children: [
                if (_mapSdkReady)
                  NaverMap(
                    options: const NaverMapViewOptions(
                      initialCameraPosition: NCameraPosition(
                        target: NLatLng(37.5665, 126.9780),
                        zoom: 14,
                      ),
                      zoomGesturesEnable: true,
                      locationButtonEnable: false,
                    ),
                    onMapReady: (ctrl) {
                      _mapCtrl = ctrl;
                      if (_track.isNotEmpty) {
                        _updateOverlays();
                        _fitPolyline();
                      }
                    },
                  )
                else
                  const Center(child: CircularProgressIndicator()),
                if (_loading)
                  const Center(child: CircularProgressIndicator()),
                if (!_loading && _track.isEmpty)
                  const Center(
                    child: Text(
                      '이동 기록이 없습니다',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
              ],
            ),
          ),

          // ── 타임라인 리스트 ────────────────────────────────────────────
          Expanded(
            flex: 3,
            child: _TrackTimeline(
              track:         _track,
              highlightIndex: _playing ? _playIndex : null,
              onTap:         (i) {
                _stopPlay();
                setState(() => _playIndex = i);
                _updateOverlays();
                
                final p = _track[i];
                _mapCtrl?.updateCamera(
                  NCameraUpdate.scrollAndZoomTo(target: NLatLng(p.lat, p.lng))
                    ..setAnimation(animation: NCameraAnimation.easing),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  String _selectedNickname() {
    return _members
            .where((m) => m.userId == _selectedUserId)
            .firstOrNull
            ?.nickname ??
        '멤버';
  }

  String _formatTime(DateTime dt) =>
      DateFormat('HH:mm:ss').format(dt.toLocal());
}

// ─────────────────────────────────────────────────────────────────────────────
// 필터 패널
// ─────────────────────────────────────────────────────────────────────────────
class _FilterPanel extends StatelessWidget {
  const _FilterPanel({
    required this.members,
    required this.selectedUserId,
    required this.preset,
    required this.from,
    required this.to,
    required this.onMemberChanged,
    required this.onPresetChanged,
  });

  final List<SessionMember> members;
  final String?   selectedUserId;
  final DatePreset preset;
  final DateTime  from;
  final DateTime  to;
  final ValueChanged<String?> onMemberChanged;
  final ValueChanged<DatePreset> onPresetChanged;

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('MM/dd');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<String>(
            initialValue: selectedUserId,
            decoration: const InputDecoration(
              labelText: '멤버 선택',
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              border: OutlineInputBorder(),
            ),
            items: members
                .map((m) => DropdownMenuItem(
                      value: m.userId,
                      child: Text(m.nickname),
                    ))
                .toList(),
            onChanged: onMemberChanged,
          ),
          const SizedBox(height: 8),

          Row(
            children: [
              _PresetBtn(
                label: '오늘',
                selected: preset == DatePreset.today,
                onTap: () => onPresetChanged(DatePreset.today),
              ),
              const SizedBox(width: 8),
              _PresetBtn(
                label: '최근 7일',
                selected: preset == DatePreset.week,
                onTap: () => onPresetChanged(DatePreset.week),
              ),
              const SizedBox(width: 8),
              _PresetBtn(
                label: preset == DatePreset.custom
                    ? '${fmt.format(from)} ~ ${fmt.format(to)}'
                    : '직접 선택',
                selected: preset == DatePreset.custom,
                onTap: () => onPresetChanged(DatePreset.custom),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PresetBtn extends StatelessWidget {
  const _PresetBtn({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? const Color(0xFF2196F3)
                : Colors.grey[100],
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: selected ? Colors.white : Colors.black87,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// 타임라인 리스트
// ─────────────────────────────────────────────────────────────────────────────
class _TrackTimeline extends StatelessWidget {
  const _TrackTimeline({
    required this.track,
    required this.highlightIndex,
    required this.onTap,
  });

  final List<TrackPoint> track;
  final int?  highlightIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    if (track.isEmpty) {
      return const Center(
        child: Text('기록이 없습니다', style: TextStyle(color: Colors.grey)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: track.length,
      itemBuilder: (ctx, i) {
        final p = track[i];
        final highlighted = i == highlightIndex;
        return InkWell(
          onTap: () => onTap(i),
          child: Container(
            color: highlighted
                ? const Color(0xFF2196F3).withValues(alpha: 0.1)
                : null,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                Column(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: highlighted
                            ? const Color(0xFF2196F3)
                            : _statusColor(p.status),
                        shape: BoxShape.circle,
                      ),
                    ),
                    if (i < track.length - 1)
                      Container(
                        width: 2,
                        height: 24,
                        color: Colors.grey[300],
                      ),
                  ],
                ),
                const SizedBox(width: 12),

                Text(
                  DateFormat('HH:mm:ss').format(p.recordedAt.toLocal()),
                  style: const TextStyle(
                    fontSize: 13,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 12),

                if (p.speed != null)
                  Text(
                    '${(p.speed! * 3.6).toStringAsFixed(1)} km/h',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                const Spacer(),

                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: _statusColor(p.status).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    _statusLabel(p.status),
                    style: TextStyle(
                      fontSize: 11,
                      color: _statusColor(p.status),
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

  Color _statusColor(String status) {
    switch (status) {
      case 'moving': return Colors.green;
      case 'sos':    return Colors.red;
      default:       return Colors.grey;
    }
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'moving':  return '이동';
      case 'stopped': return '정지';
      case 'sos':     return 'SOS';
      default:        return status;
    }
  }
}
