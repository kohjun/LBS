// lib/features/game/presentation/qr_scanner_screen.dart
//
// QR 코드 스캔 화면. 미션 ID와 일치하면 미니게임 래퍼로 이동합니다.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../providers/game_provider.dart';
import 'minigames/minigame_wrapper_screen.dart';

class QrScannerScreen extends ConsumerStatefulWidget {
  const QrScannerScreen({
    super.key,
    required this.sessionId,
  });

  final String sessionId;

  @override
  ConsumerState<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends ConsumerState<QrScannerScreen> {
  bool _scanned = false;
  final MobileScannerController _controller = MobileScannerController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_scanned) return;

    final code = capture.barcodes.firstOrNull?.rawValue;
    if (code == null) return;

    final missions = ref.read(gameProvider(widget.sessionId)).myMissions;
    final matched = missions.where(
      (m) => m.id == code && m.status != MissionStatus.completed,
    ).firstOrNull;

    if (matched == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('일치하는 미션 QR이 아닙니다.'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    _scanned = true;
    _controller.stop();

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => MinigameWrapperScreen(
          sessionId: widget.sessionId,
          missionId: matched.id,
          missionTitle: matched.title,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
            ),
            // 상단 바
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                color: Colors.black.withValues(alpha: 0.6),
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () => Navigator.of(context).maybePop(),
                      child: const Text(
                        '< 뒤로',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const Spacer(),
                    const Text(
                      'QR 스캔',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    const SizedBox(width: 48), // 균형 맞춤
                  ],
                ),
              ),
            ),
            // 안내 텍스트
            Positioned(
              bottom: 60,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 24, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    '미션 QR 코드를 카메라에 비추세요',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
