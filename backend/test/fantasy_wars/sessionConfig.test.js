import test from 'node:test';
import assert from 'node:assert/strict';

import { normalizeFantasyWarsDuelSettings } from '../../src/game/plugins/fantasy_wars_artifact/sessionConfig.js';

test('normalizeFantasyWarsDuelSettings falls back to plugin defaults', () => {
  const config = normalizeFantasyWarsDuelSettings();

  assert.deepEqual(config, {
    duelRangeMeters: 20,
    bleEvidenceFreshnessMs: 12000,
    allowGpsFallbackWithoutBle: false,
    locationFreshnessMs: 45000,
  });
});

test('normalizeFantasyWarsDuelSettings clamps invalid numeric values', () => {
  const config = normalizeFantasyWarsDuelSettings({
    duelRangeMeters: 999,
    bleEvidenceFreshnessMs: 1000,
    locationFreshnessMs: '600000',
  });

  assert.equal(config.duelRangeMeters, 100);
  assert.equal(config.bleEvidenceFreshnessMs, 2000);
  assert.equal(config.locationFreshnessMs, 300000);
});

test('normalizeFantasyWarsDuelSettings keeps explicit host choices', () => {
  const config = normalizeFantasyWarsDuelSettings({
    allowGpsFallbackWithoutBle: true,
    bleEvidenceFreshnessMs: 8000,
  });

  assert.equal(config.allowGpsFallbackWithoutBle, true);
  assert.equal(config.bleEvidenceFreshnessMs, 8000);
});
