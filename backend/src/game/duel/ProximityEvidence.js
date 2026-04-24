'use strict';

const proximityEvidenceBySession = new Map();

function pairKey(observerId, targetId) {
  return `${observerId}->${targetId}`;
}

function getSessionStore(sessionId, createIfMissing = false) {
  if (!createIfMissing) {
    return proximityEvidenceBySession.get(sessionId) ?? null;
  }

  let store = proximityEvidenceBySession.get(sessionId);
  if (!store) {
    store = new Map();
    proximityEvidenceBySession.set(sessionId, store);
  }
  return store;
}

function normalizeSource(source) {
  return source === 'ble' ? 'ble' : 'gps_fallback';
}

function sourcePriority(source) {
  return source === 'ble' ? 2 : 1;
}

export function recordProximityEvidence({
  sessionId,
  observerId,
  targetId,
  source = 'gps_fallback',
  distanceMeters = null,
  rssi = null,
  seenAt = Date.now(),
} = {}) {
  if (!sessionId || !observerId || !targetId || observerId === targetId) {
    return null;
  }

  const sessionStore = getSessionStore(sessionId, true);
  const normalized = {
    observerId,
    targetId,
    source: normalizeSource(source),
    distanceMeters:
      typeof distanceMeters === 'number' && Number.isFinite(distanceMeters)
        ? Math.max(0, Math.round(distanceMeters))
        : null,
    rssi:
      typeof rssi === 'number' && Number.isFinite(rssi)
        ? Math.round(rssi)
        : null,
    seenAt:
      typeof seenAt === 'number' && Number.isFinite(seenAt)
        ? Math.round(seenAt)
        : Date.now(),
  };

  sessionStore.set(pairKey(observerId, targetId), normalized);
  return normalized;
}

export function recordProximityPayload({
  sessionId,
  observerId,
  expectedTargetId = null,
  proximity,
  now = Date.now(),
} = {}) {
  if (!proximity || typeof proximity !== 'object') {
    return null;
  }

  const targetId = proximity.targetUserId;
  if (!targetId || (expectedTargetId && targetId !== expectedTargetId)) {
    return null;
  }

  return recordProximityEvidence({
    sessionId,
    observerId,
    targetId,
    source: proximity.source,
    distanceMeters: proximity.distanceMeters,
    rssi: proximity.rssi,
    seenAt: proximity.seenAt ?? now,
  });
}

export function getPairProximityEvidence(
  sessionId,
  userA,
  userB,
  { freshnessMs = 12_000, now = Date.now() } = {},
) {
  const sessionStore = getSessionStore(sessionId, false);
  if (!sessionStore) {
    return {
      available: false,
      bestSource: null,
      reports: [],
      mutual: false,
    };
  }

  const reports = [
    sessionStore.get(pairKey(userA, userB)),
    sessionStore.get(pairKey(userB, userA)),
  ]
    .filter(Boolean)
    .filter((report) => (now - report.seenAt) <= freshnessMs)
    .sort((left, right) => {
      const bySource = sourcePriority(right.source) - sourcePriority(left.source);
      if (bySource !== 0) {
        return bySource;
      }
      return right.seenAt - left.seenAt;
    });

  const directions = new Set(reports.map((report) => `${report.observerId}:${report.targetId}`));

  return {
    available: reports.length > 0,
    bestSource: reports[0]?.source ?? null,
    reports,
    mutual: directions.size >= 2,
  };
}

export function clearProximityEvidence(sessionId = null) {
  if (!sessionId) {
    proximityEvidenceBySession.clear();
    return;
  }

  proximityEvidenceBySession.delete(sessionId);
}
