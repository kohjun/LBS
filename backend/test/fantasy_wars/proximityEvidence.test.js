import test from 'node:test';
import assert from 'node:assert/strict';

import {
  clearProximityEvidence,
  getPairProximityEvidence,
  recordProximityPayload,
} from '../../src/game/duel/ProximityEvidence.js';

test.afterEach(() => {
  clearProximityEvidence();
});

test('pair proximity prefers BLE evidence over GPS fallback', () => {
  recordProximityPayload({
    sessionId: 'session-1',
    observerId: 'alpha',
    expectedTargetId: 'beta',
    proximity: {
      targetUserId: 'beta',
      source: 'gps_fallback',
      distanceMeters: 14.4,
      seenAt: 10_000,
    },
  });

  recordProximityPayload({
    sessionId: 'session-1',
    observerId: 'beta',
    expectedTargetId: 'alpha',
    proximity: {
      targetUserId: 'alpha',
      source: 'ble',
      rssi: -62,
      seenAt: 10_100,
    },
  });

  const result = getPairProximityEvidence(
    'session-1',
    'alpha',
    'beta',
    { freshnessMs: 5_000, now: 12_000 },
  );

  assert.equal(result.available, true);
  assert.equal(result.bestSource, 'ble');
  assert.equal(result.mutual, true);
  assert.equal(result.reports.length, 2);
});

test('stale proximity evidence is ignored', () => {
  recordProximityPayload({
    sessionId: 'session-2',
    observerId: 'alpha',
    expectedTargetId: 'beta',
    proximity: {
      targetUserId: 'beta',
      source: 'ble',
      seenAt: 1_000,
    },
  });

  const result = getPairProximityEvidence(
    'session-2',
    'alpha',
    'beta',
    { freshnessMs: 2_000, now: 5_500 },
  );

  assert.equal(result.available, false);
  assert.equal(result.bestSource, null);
  assert.equal(result.mutual, false);
});

test('unexpected challenge targets are rejected while recording proximity payloads', () => {
  const recorded = recordProximityPayload({
    sessionId: 'session-3',
    observerId: 'alpha',
    expectedTargetId: 'beta',
    proximity: {
      targetUserId: 'gamma',
      source: 'ble',
      seenAt: 2_000,
    },
  });

  assert.equal(recorded, null);
  const result = getPairProximityEvidence(
    'session-3',
    'alpha',
    'beta',
    { freshnessMs: 5_000, now: 2_100 },
  );
  assert.equal(result.available, false);
});
