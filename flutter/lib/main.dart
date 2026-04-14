import 'dart:async';
import 'dart:ui';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/services/app_initialization_service.dart';
import 'core/services/fcm_service.dart';

void _logUnhandledError(
  String source,
  Object error,
  StackTrace stackTrace,
) {
  debugPrint('[$source] $error');
  debugPrintStack(label: '[$source] stack', stackTrace: stackTrace);
}

Future<void> main() async {
  await runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      _logUnhandledError(
        'FlutterError',
        details.exception,
        details.stack ?? StackTrace.current,
      );
    };

    PlatformDispatcher.instance.onError = (error, stackTrace) {
      _logUnhandledError('PlatformDispatcher', error, stackTrace);
      return false;
    };

    ErrorWidget.builder = (details) {
      _logUnhandledError(
        'ErrorWidget',
        details.exception,
        details.stack ?? StackTrace.current,
      );
      return Material(
        color: Colors.red.shade50,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'A rendering error occurred.\n${details.exception}',
              style: const TextStyle(color: Colors.black87),
            ),
          ),
        ),
      );
    };

    try {
      FirebaseMessaging.onBackgroundMessage(FcmService.onBackgroundMessage);
      debugPrint('[Startup] FCM background handler registered');
    } catch (e, stackTrace) {
      _logUnhandledError('FCM background handler', e, stackTrace);
    }

    // SharedPreferences를 첫 프레임 전에 미리 warm-up합니다.
    // 이후 getInstance() 호출이 즉시 반환되어 resetBackgroundFlags 지연이 사라집니다.
    unawaited(
      AppInitializationService()
          .getPrefs()
          .catchError((Object error, StackTrace stackTrace) {
        _logUnhandledError('PrefsWarmup', error, stackTrace);
      }),
    );

    runApp(
      const ProviderScope(
        child: LocationApp(),
      ),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        AppInitializationService()
            .resetBackgroundFlags()
            .catchError((Object error, StackTrace stackTrace) {
          _logUnhandledError('DeferredBootstrap', error, stackTrace);
        }),
      );
    });
  }, (error, stackTrace) {
    _logUnhandledError('runZonedGuarded', error, stackTrace);
  });
}
