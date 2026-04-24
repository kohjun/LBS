import '../../features/map/presentation/map_session_models.dart';

class FwDuelProximityContext {
  const FwDuelProximityContext({
    required this.targetUserId,
    required this.source,
    required this.seenAt,
    this.distanceMeters,
    this.rssi,
  });

  final String targetUserId;
  final String source;
  final int seenAt;
  final int? distanceMeters;
  final int? rssi;

  Map<String, dynamic> toMap() => {
        'targetUserId': targetUserId,
        'source': source,
        'seenAt': seenAt,
        if (distanceMeters != null) 'distanceMeters': distanceMeters,
        if (rssi != null) 'rssi': rssi,
      };
}

class FantasyWarsProximityService {
  const FantasyWarsProximityService();

  static const int bleFreshnessMs = 12000;
  static const double gpsFallbackRangeMeters = 20.0;

  FwDuelProximityContext? forTarget({
    required String targetUserId,
    required MapSessionState mapState,
    required String? myUserId,
    bool allowGpsFallbackWithoutBle = false,
    int bleFreshnessWindowMs = bleFreshnessMs,
    double gpsFallbackMaxRangeMeters = gpsFallbackRangeMeters,
    int? nowMs,
  }) {
    if (myUserId == null || targetUserId == myUserId) {
      return null;
    }

    final timestamp = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final bleContact = mapState.bleContacts[targetUserId];
    if (bleContact != null
        && (timestamp - bleContact.seenAtMs) <= bleFreshnessWindowMs) {
      return FwDuelProximityContext(
        targetUserId: targetUserId,
        source: 'ble',
        seenAt: bleContact.seenAtMs,
        rssi: bleContact.rssi,
      );
    }

    if (!allowGpsFallbackWithoutBle) {
      return null;
    }

    final distanceMeters = mapState.memberDistances[targetUserId];
    if (distanceMeters == null ||
        !distanceMeters.isFinite ||
        distanceMeters > gpsFallbackMaxRangeMeters) {
      return null;
    }

    return FwDuelProximityContext(
      targetUserId: targetUserId,
      source: 'gps_fallback',
      seenAt: timestamp,
      distanceMeters: distanceMeters.round(),
    );
  }

  bool canChallenge({
    required String targetUserId,
    required MapSessionState mapState,
    required String? myUserId,
    bool allowGpsFallbackWithoutBle = false,
    int bleFreshnessWindowMs = bleFreshnessMs,
    double gpsFallbackMaxRangeMeters = gpsFallbackRangeMeters,
  }) {
    return forTarget(
          targetUserId: targetUserId,
          mapState: mapState,
          myUserId: myUserId,
          allowGpsFallbackWithoutBle: allowGpsFallbackWithoutBle,
          bleFreshnessWindowMs: bleFreshnessWindowMs,
          gpsFallbackMaxRangeMeters: gpsFallbackMaxRangeMeters,
        ) !=
        null;
  }
}
