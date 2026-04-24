'use strict';

// Fantasy Wars Artifact plugin config and role defaults.

export const configSchema = {
  teamCount: { type: 'number', default: 3, min: 2, max: 4 },
  controlPointCount: { type: 'number', default: 5, min: 3, max: 9 },
  captureDurationSec: { type: 'number', default: 30, min: 15, max: 300 },
  controlPointHoldDurationSec: { type: 'number', default: 20, min: 0, max: 120 },
  captureRadiusMeters: { type: 'number', default: 30, min: 5, max: 200 },
  captureReadyWindowMs: { type: 'number', default: 5000, min: 1000, max: 15000 },
  duelRangeMeters: { type: 'number', default: 20, min: 1, max: 100 },
  bleEvidenceFreshnessMs: { type: 'number', default: 12000, min: 2000, max: 60000 },
  allowGpsFallbackWithoutBle: { type: 'boolean', default: false },
  locationFreshnessMs: { type: 'number', default: 45000, min: 5000, max: 300000 },
  reviveBaseChance: { type: 'number', default: 0.3, min: 0.1, max: 1.0 },
  reviveStepChance: { type: 'number', default: 0.1, min: 0.0, max: 0.5 },
  reviveMaxChance: { type: 'number', default: 0.8, min: 0.3, max: 1.0 },
  controlPoints: { type: 'array', default: [] },
  skillCooldowns: {
    type: 'object',
    default: {
      priest: 600,
      mage: 600,
      ranger: 300,
      rogue: 600,
    },
  },
  winByMajority: { type: 'boolean', default: false },
  winByMasterElim: { type: 'boolean', default: true },
};

export const defaultConfig = {
  teamCount: 3,
  controlPointCount: 5,
  captureDurationSec: 30,
  controlPointHoldDurationSec: 20,
  captureRadiusMeters: 30,
  captureReadyWindowMs: 5000,
  duelRangeMeters: 20,
  bleEvidenceFreshnessMs: 12000,
  allowGpsFallbackWithoutBle: false,
  locationFreshnessMs: 45000,
  reviveBaseChance: 0.3,
  reviveStepChance: 0.1,
  reviveMaxChance: 0.8,
  controlPoints: [],
  skillCooldowns: {
    priest: 600,
    mage: 600,
    ranger: 300,
    rogue: 600,
  },
  winByMajority: false,
  winByMasterElim: true,
};

export function resolveDuelConfig(config = {}) {
  return {
    duelRangeMeters: config.duelRangeMeters ?? defaultConfig.duelRangeMeters,
    bleEvidenceFreshnessMs:
      config.bleEvidenceFreshnessMs ?? defaultConfig.bleEvidenceFreshnessMs,
    allowGpsFallbackWithoutBle:
      config.allowGpsFallbackWithoutBle ?? defaultConfig.allowGpsFallbackWithoutBle,
    locationFreshnessMs:
      config.locationFreshnessMs ?? defaultConfig.locationFreshnessMs,
  };
}

export const GUILD_IDS = ['guild_alpha', 'guild_beta', 'guild_gamma', 'guild_delta'];

// Guild master is a status flag, not a separate job.
export const JOB_PRIORITY = [
  'warrior',
  'priest',
  'mage',
  'ranger',
  'rogue',
  'warrior',
  'ranger',
  'priest',
  'mage',
  'rogue',
];
