import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

enum BlePresenceLifecycleState {
  idle,
  unsupported,
  requestingPermission,
  permissionDenied,
  bluetoothUnavailable,
  starting,
  running,
  error,
}

class BlePresenceStatus {
  const BlePresenceStatus({
    required this.state,
    this.message,
  });

  final BlePresenceLifecycleState state;
  final String? message;
}

class BlePresenceSighting {
  const BlePresenceSighting({
    required this.userId,
    required this.rssi,
    required this.seenAtMs,
    required this.deviceId,
  });

  final String userId;
  final int rssi;
  final int seenAtMs;
  final String deviceId;
}

class FantasyWarsBlePresenceService {
  FantasyWarsBlePresenceService._internal();

  static final FantasyWarsBlePresenceService _instance =
      FantasyWarsBlePresenceService._internal();

  factory FantasyWarsBlePresenceService() => _instance;

  static const String serviceUuid =
      '6e65d2f6-8bb5-42fb-9a66-1c4f1b9f4e11';
  static const int _manufacturerId = 0x0FFF;
  static const int _payloadVersion = 1;

  final FlutterReactiveBle _ble = FlutterReactiveBle();
  final FlutterBlePeripheral _peripheral = FlutterBlePeripheral();
  final _sightingsController = StreamController<BlePresenceSighting>.broadcast();
  final _statusController = StreamController<BlePresenceStatus>.broadcast();

  StreamSubscription<DiscoveredDevice>? _scanSub;
  StreamSubscription<BleStatus>? _statusSub;

  String? _sessionId;
  String? _userId;
  bool _shouldRun = false;
  bool _isRunning = false;
  Map<String, String> _tokenToUserId = const {};
  BlePresenceStatus _status =
      const BlePresenceStatus(state: BlePresenceLifecycleState.idle);

  Stream<BlePresenceSighting> get sightings => _sightingsController.stream;
  Stream<BlePresenceStatus> get statuses => _statusController.stream;
  bool get isRunning => _isRunning;
  BlePresenceStatus get status => _status;

  Future<void> start({
    required String sessionId,
    required String userId,
    required Iterable<String> memberUserIds,
  }) async {
    if (!Platform.isAndroid) {
      _emitStatus(
        BlePresenceLifecycleState.unsupported,
        message: 'Android BLE scanning is only enabled on supported devices.',
      );
      return;
    }

    final sameIdentity = _sessionId == sessionId && _userId == userId;
    _sessionId = sessionId;
    _userId = userId;
    _tokenToUserId = {
      for (final memberUserId in memberUserIds)
        _tokenFor(sessionId, memberUserId): memberUserId,
    };
    _shouldRun = true;

    if (sameIdentity && _isRunning) {
      return;
    }

    _ensureStatusSubscription();
    _emitStatus(BlePresenceLifecycleState.requestingPermission);
    final granted = await _ensurePermissions();
    if (!granted) {
      _isRunning = false;
      debugPrint('[FW-BLE] permissions denied, BLE presence disabled');
      _emitStatus(
        BlePresenceLifecycleState.permissionDenied,
        message: 'Bluetooth and location permissions are required.',
      );
      return;
    }

    _emitStatus(BlePresenceLifecycleState.starting);
    await _restartIfReady();
  }

  Future<void> stop() async {
    _shouldRun = false;
    _isRunning = false;
    _sessionId = null;
    _userId = null;
    _tokenToUserId = const {};

    await _scanSub?.cancel();
    _scanSub = null;

    try {
      await _peripheral.stop();
    } catch (_) {}

    await _statusSub?.cancel();
    _statusSub = null;
    _emitStatus(BlePresenceLifecycleState.idle);
  }

  void _ensureStatusSubscription() {
    _statusSub ??= _ble.statusStream.listen((status) {
      if (!_shouldRun) {
        return;
      }

      if (status == BleStatus.ready) {
        unawaited(_restartIfReady());
        return;
      }

      _isRunning = false;
      unawaited(_scanSub?.cancel() ?? Future<void>.value());
      _scanSub = null;
      _emitStatus(
        BlePresenceLifecycleState.bluetoothUnavailable,
        message: _availabilityMessage(status),
      );
    });
  }

  Future<bool> _ensurePermissions() async {
    if (!Platform.isAndroid) {
      return false;
    }

    final permissions = <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
      Permission.location,
    ];
    final results = await permissions.request();
    return results.values.every((status) => status.isGranted);
  }

  Future<void> _restartIfReady() async {
    if (!_shouldRun || _sessionId == null || _userId == null) {
      return;
    }
    if (_ble.status != BleStatus.ready) {
      _emitStatus(
        BlePresenceLifecycleState.bluetoothUnavailable,
        message: _availabilityMessage(_ble.status),
      );
      return;
    }

    final advertisingReady = await _startAdvertising();
    final scanningReady = await _startScanning();
    _isRunning = advertisingReady && scanningReady;
    _emitStatus(
      _isRunning
          ? BlePresenceLifecycleState.running
          : BlePresenceLifecycleState.error,
      message: _isRunning
          ? 'BLE proximity scanning is active.'
          : 'BLE proximity could not be started cleanly.',
    );
  }

  Future<bool> _startAdvertising() async {
    final sessionId = _sessionId;
    final userId = _userId;
    if (sessionId == null || userId == null) {
      return false;
    }

    final advertiseData = AdvertiseData(
      serviceUuid: serviceUuid,
      localName: _localNameFor(userId),
      manufacturerId: _manufacturerId,
      manufacturerData: Uint8List.fromList(
        _payloadBytesFor(sessionId, userId),
      ),
    );

    final settings = AdvertiseSettings(
      advertiseMode: AdvertiseMode.advertiseModeBalanced,
      txPowerLevel: AdvertiseTxPower.advertiseTxPowerMedium,
      timeout: 0,
    );

    try {
      await _peripheral.stop();
    } catch (_) {}

    try {
      await _peripheral.start(
        advertiseData: advertiseData,
        advertiseSettings: settings,
      );
      return true;
    } catch (error) {
      debugPrint('[FW-BLE] advertise start failed: $error');
      _emitStatus(
        BlePresenceLifecycleState.error,
        message: 'BLE advertising could not be started.',
      );
      return false;
    }
  }

  Future<bool> _startScanning() async {
    await _scanSub?.cancel();
    try {
      _scanSub = _ble
          .scanForDevices(
            withServices: [Uuid.parse(serviceUuid)],
            scanMode: ScanMode.lowLatency,
            requireLocationServicesEnabled: true,
          )
          .listen(
            _handleScanResult,
            onError: (Object error) {
              _isRunning = false;
              debugPrint('[FW-BLE] scan failed: $error');
              _emitStatus(
                BlePresenceLifecycleState.error,
                message: 'BLE scanning failed while running.',
              );
            },
          );
      return true;
    } catch (error) {
      debugPrint('[FW-BLE] scan start failed: $error');
      _emitStatus(
        BlePresenceLifecycleState.error,
        message: 'BLE scanning could not be started.',
      );
      return false;
    }
  }

  void _handleScanResult(DiscoveredDevice device) {
    final userId = _resolveUserId(device);
    if (userId == null || userId == _userId) {
      return;
    }

    _sightingsController.add(
      BlePresenceSighting(
        userId: userId,
        rssi: device.rssi,
        seenAtMs: DateTime.now().millisecondsSinceEpoch,
        deviceId: device.id,
      ),
    );
  }

  String? _resolveUserId(DiscoveredDevice device) {
    if (device.manufacturerData.length < 11) {
      return null;
    }

    final payload = device.manufacturerData.sublist(2);
    if (payload.length < 9 ||
        payload[0] != 0x46 ||
        payload[1] != 0x57 ||
        payload[2] != _payloadVersion) {
      return null;
    }

    final tokenHex = _bytesToHex(payload.sublist(3));
    return _tokenToUserId[tokenHex];
  }

  String _localNameFor(String userId) {
    final safeUserId = userId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
    final suffix = safeUserId.length <= 8
        ? safeUserId
        : safeUserId.substring(safeUserId.length - 8);
    return 'FW$suffix';
  }

  List<int> _payloadBytesFor(String sessionId, String userId) {
    return <int>[
      0x46,
      0x57,
      _payloadVersion,
      ..._hexToBytes(_tokenFor(sessionId, userId)),
    ];
  }

  String _tokenFor(String sessionId, String userId) {
    final input = '$sessionId:$userId';
    var hash = 0xcbf29ce484222325;
    const prime = 0x100000001b3;
    const mask = 0xFFFFFFFFFFFFFFFF;

    for (final codeUnit in input.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * prime) & mask;
    }

    return hash.toRadixString(16).padLeft(16, '0');
  }

  List<int> _hexToBytes(String value) {
    final bytes = <int>[];
    for (var index = 0; index < value.length; index += 2) {
      bytes.add(int.parse(value.substring(index, index + 2), radix: 16));
    }
    return bytes;
  }

  String _bytesToHex(List<int> value) {
    final buffer = StringBuffer();
    for (final byte in value) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  void _emitStatus(
    BlePresenceLifecycleState state, {
    String? message,
  }) {
    final next = BlePresenceStatus(state: state, message: message);
    _status = next;
    if (!_statusController.isClosed) {
      _statusController.add(next);
    }
  }

  String _availabilityMessage(BleStatus status) {
    switch (status.name) {
      case 'unauthorized':
        return 'Bluetooth permission is not granted.';
      case 'poweredOff':
        return 'Bluetooth is turned off.';
      case 'locationServicesDisabled':
        return 'Location services are turned off.';
      case 'unsupported':
        return 'BLE is not supported on this device.';
      default:
        return 'Bluetooth availability needs attention.';
    }
  }
}
