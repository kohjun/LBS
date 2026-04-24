import test from 'node:test';
import assert from 'node:assert/strict';

import {
  configSchema,
  defaultConfig,
  JOB_PRIORITY,
  resolveDuelConfig,
} from '../../src/game/plugins/fantasy_wars_artifact/schema.js';

test('Fantasy Wars defaults match approved ruleset', () => {
  assert.equal(configSchema.captureDurationSec.default, 30);
  assert.equal(configSchema.controlPointHoldDurationSec.default, 20);
  assert.equal(configSchema.reviveBaseChance.default, 0.3);
  assert.equal(configSchema.reviveMaxChance.default, 0.8);
  assert.equal(configSchema.bleEvidenceFreshnessMs.default, 12000);
  assert.equal(configSchema.allowGpsFallbackWithoutBle.default, false);
  assert.equal(defaultConfig.captureDurationSec, 30);
  assert.equal(defaultConfig.controlPointHoldDurationSec, 20);
  assert.equal(defaultConfig.reviveBaseChance, 0.3);
  assert.equal(defaultConfig.reviveMaxChance, 0.8);
  assert.equal(defaultConfig.bleEvidenceFreshnessMs, 12000);
  assert.equal(defaultConfig.allowGpsFallbackWithoutBle, false);
  assert.deepEqual(defaultConfig.skillCooldowns, {
    priest: 600,
    mage: 600,
    ranger: 300,
    rogue: 600,
  });
});

test('Fantasy Wars job rotation uses only approved jobs', () => {
  const allowedJobs = new Set(['warrior', 'priest', 'mage', 'ranger', 'rogue']);
  const legacyJobs = new Set(['guild_master', 'archer', 'healer', 'scout']);

  assert.ok(JOB_PRIORITY.length > 0);
  JOB_PRIORITY.forEach((job) => {
    assert.ok(allowedJobs.has(job));
    assert.equal(legacyJobs.has(job), false);
  });
});

test('resolveDuelConfig keeps realtime duel defaults aligned', () => {
  assert.deepEqual(resolveDuelConfig(), {
    duelRangeMeters: 20,
    bleEvidenceFreshnessMs: 12000,
    allowGpsFallbackWithoutBle: false,
    locationFreshnessMs: 45000,
  });

  assert.deepEqual(resolveDuelConfig({
    duelRangeMeters: 14,
    bleEvidenceFreshnessMs: 8000,
    allowGpsFallbackWithoutBle: true,
    locationFreshnessMs: 12000,
  }), {
    duelRangeMeters: 14,
    bleEvidenceFreshnessMs: 8000,
    allowGpsFallbackWithoutBle: true,
    locationFreshnessMs: 12000,
  });
});
