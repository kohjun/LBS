import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/socket_service.dart';

// 소켓의 연결 상태(true/false)를 실시간으로 방출하는 StreamProvider
final socketConnectionProvider = StreamProvider.autoDispose<bool>((ref) {
  return SocketService().onConnectionChange;
});