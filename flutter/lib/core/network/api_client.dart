// lib/core/network/api_client.dart

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const kApiBaseUrl = 'http://10.0.2.2:3000';  // 개발 서버 (배포 시 변경)

class ApiClient {
  late final Dio _dio;
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  static final ApiClient _instance = ApiClient._internal();
  factory ApiClient() => _instance;

  /// 401 복구 실패 시 호출되는 콜백 (AuthNotifier가 등록)
  static void Function()? onUnauthenticated;

  ApiClient._internal() {
    _dio = Dio(BaseOptions(
      baseUrl: kApiBaseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      headers: {'Content-Type': 'application/json'},
    ));

    // ── 인터셉터 등록 ─────────────────────────────────────────────────
    _dio.interceptors.add(InterceptorsWrapper(
      // 요청 시: 저장된 Access Token 자동 주입
      onRequest: (options, handler) async {
        final token = await _storage.read(key: 'access_token');
        if (token != null) {
          options.headers['Authorization'] = 'Bearer $token';
        }
        return handler.next(options);
      },

      // 에러 시: 401이면 토큰 갱신 후 재요청 (에러 코드 무관하게 시도)
      onError: (error, handler) async {
        if (error.response?.statusCode == 401) {
          try {
            await _refreshAccessToken();

            // 갱신된 토큰으로 원래 요청 재시도
            final retryOptions = error.requestOptions;
            final newToken = await _storage.read(key: 'access_token');
            retryOptions.headers['Authorization'] = 'Bearer $newToken';

            final retryResponse = await _dio.fetch(retryOptions);
            return handler.resolve(retryResponse);
          } catch (_) {
            // 갱신 실패 → 토큰 삭제 + 로그인 화면으로 이동
            await clearTokens();
            onUnauthenticated?.call();
            return handler.reject(error);
          }
        }
        return handler.next(error);
      },
    ));
  }

  // ─────────────────────────────────────────────────────────────────────────
  // HTTP 메서드 래퍼
  // ─────────────────────────────────────────────────────────────────────────
  Future<Response> get(String path, {Map<String, dynamic>? queryParams}) =>
      _dio.get(path, queryParameters: queryParams);

  Future<Response> post(String path, {dynamic data}) =>
      _dio.post(path, data: data);

  Future<Response> patch(String path, {dynamic data}) =>
      _dio.patch(path, data: data);

  Future<Response> delete(String path) => _dio.delete(path);

  // ─────────────────────────────────────────────────────────────────────────
  // 토큰 관리
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> saveTokens({
    required String accessToken,
    String? refreshToken,
  }) async {
    await _storage.write(key: 'access_token', value: accessToken);
    if (refreshToken != null) {
      await _storage.write(key: 'refresh_token', value: refreshToken);
    }
  }

  Future<void> clearTokens() async {
    await _storage.deleteAll();
  }

  Future<String?> getAccessToken() => _storage.read(key: 'access_token');

  // Refresh Token으로 Access Token 갱신
  // 저장된 refresh_token을 body에 실어 전송 → 쿠키 없는 환경(백그라운드)도 지원
  Future<void> _refreshAccessToken() async {
    final storedRefreshToken = await _storage.read(key: 'refresh_token');

    final response = await Dio(BaseOptions(baseUrl: kApiBaseUrl)).post(
      '/auth/refresh',
      data: storedRefreshToken != null
          ? {'refreshToken': storedRefreshToken}
          : null,
      options: Options(extra: {'withCredentials': true}),
    );

    final newAccessToken  = response.data['accessToken']  as String;
    final newRefreshToken = response.data['refreshToken'] as String?;
    await saveTokens(accessToken: newAccessToken, refreshToken: newRefreshToken);
  }
}
