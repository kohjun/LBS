import 'package:flutter_test/flutter_test.dart';
import 'package:location_sharing_app/core/services/fantasy_wars_proximity_service.dart';
import 'package:location_sharing_app/features/map/presentation/map_session_models.dart';

MapSessionState _mapState({
  Map<String, BleMemberContact> bleContacts = const {},
  Map<String, double> memberDistances = const {},
}) {
  return MapSessionState(
    members: const {},
    bleContacts: bleContacts,
    memberDistances: memberDistances,
  );
}

void main() {
  group('FantasyWarsProximityService', () {
    const service = FantasyWarsProximityService();

    test('returns null when my user id is missing or target is self', () {
      final mapState = _mapState();

      expect(
        service.forTarget(
          targetUserId: 'enemy-1',
          mapState: mapState,
          myUserId: null,
        ),
        isNull,
      );

      expect(
        service.forTarget(
          targetUserId: 'me',
          mapState: mapState,
          myUserId: 'me',
        ),
        isNull,
      );
    });

    test('prefers fresh BLE evidence over GPS fallback', () {
      const nowMs = 20000;
      final mapState = _mapState(
        bleContacts: const {
          'enemy-1': BleMemberContact(
            userId: 'enemy-1',
            rssi: -58,
            seenAtMs: 15000,
            deviceId: 'ble-1',
          ),
        },
        memberDistances: const {
          'enemy-1': 4.2,
        },
      );

      final result = service.forTarget(
        targetUserId: 'enemy-1',
        mapState: mapState,
        myUserId: 'me',
        allowGpsFallbackWithoutBle: true,
        bleFreshnessWindowMs: 6000,
        gpsFallbackMaxRangeMeters: 20,
        nowMs: nowMs,
      );

      expect(result, isNotNull);
      expect(result?.source, 'ble');
      expect(result?.seenAt, 15000);
      expect(result?.rssi, -58);
      expect(result?.distanceMeters, isNull);
    });

    test('rejects stale BLE evidence when GPS fallback is disabled', () {
      const nowMs = 30000;
      final mapState = _mapState(
        bleContacts: const {
          'enemy-1': BleMemberContact(
            userId: 'enemy-1',
            rssi: -61,
            seenAtMs: 10000,
            deviceId: 'ble-1',
          ),
        },
        memberDistances: const {
          'enemy-1': 8.0,
        },
      );

      final result = service.forTarget(
        targetUserId: 'enemy-1',
        mapState: mapState,
        myUserId: 'me',
        allowGpsFallbackWithoutBle: false,
        bleFreshnessWindowMs: 5000,
        nowMs: nowMs,
      );

      expect(result, isNull);
    });

    test('falls back to GPS when allowed and target is within range', () {
      const nowMs = 45000;
      final mapState = _mapState(
        memberDistances: const {
          'enemy-1': 12.6,
        },
      );

      final result = service.forTarget(
        targetUserId: 'enemy-1',
        mapState: mapState,
        myUserId: 'me',
        allowGpsFallbackWithoutBle: true,
        gpsFallbackMaxRangeMeters: 20,
        nowMs: nowMs,
      );

      expect(result, isNotNull);
      expect(result?.source, 'gps_fallback');
      expect(result?.distanceMeters, 13);
      expect(result?.seenAt, nowMs);
      expect(result?.rssi, isNull);
    });

    test('rejects GPS fallback when distance is invalid or out of range', () {
      final mapState = _mapState(
        memberDistances: const {
          'enemy-far': 25.1,
          'enemy-bad': double.infinity,
        },
      );

      expect(
        service.forTarget(
          targetUserId: 'enemy-far',
          mapState: mapState,
          myUserId: 'me',
          allowGpsFallbackWithoutBle: true,
          gpsFallbackMaxRangeMeters: 20,
        ),
        isNull,
      );

      expect(
        service.forTarget(
          targetUserId: 'enemy-bad',
          mapState: mapState,
          myUserId: 'me',
          allowGpsFallbackWithoutBle: true,
          gpsFallbackMaxRangeMeters: 20,
        ),
        isNull,
      );
    });

    test('canChallenge matches forTarget availability', () {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final mapState = _mapState(
        bleContacts: {
          'enemy-1': BleMemberContact(
            userId: 'enemy-1',
            rssi: -55,
            seenAtMs: nowMs - 500,
            deviceId: 'ble-1',
          ),
        },
      );

      expect(
        service.canChallenge(
          targetUserId: 'enemy-1',
          mapState: mapState,
          myUserId: 'me',
          bleFreshnessWindowMs: 1000,
        ),
        isTrue,
      );

      expect(
        service.canChallenge(
          targetUserId: 'enemy-2',
          mapState: mapState,
          myUserId: 'me',
          allowGpsFallbackWithoutBle: false,
        ),
        isFalse,
      );
    });
  });
}
