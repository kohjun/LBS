'use strict';

import { configSchema, defaultConfig } from './schema.js';

const clampNumberFromSchema = (value, key) => {
  const parsed = Number(value);
  const fallback = defaultConfig[key];
  const schema = configSchema[key] ?? {};

  if (!Number.isFinite(parsed)) {
    return fallback;
  }

  const min = Number.isFinite(schema.min) ? schema.min : parsed;
  const max = Number.isFinite(schema.max) ? schema.max : parsed;
  return Math.min(Math.max(Math.trunc(parsed), min), max);
};

const resolveBooleanFromDefault = (value, key) => (
  typeof value === 'boolean' ? value : defaultConfig[key]
);

export function normalizeFantasyWarsDuelSettings(gameConfig = {}) {
  return {
    duelRangeMeters: clampNumberFromSchema(
      gameConfig.duelRangeMeters,
      'duelRangeMeters',
    ),
    bleEvidenceFreshnessMs: clampNumberFromSchema(
      gameConfig.bleEvidenceFreshnessMs,
      'bleEvidenceFreshnessMs',
    ),
    allowGpsFallbackWithoutBle: resolveBooleanFromDefault(
      gameConfig.allowGpsFallbackWithoutBle,
      'allowGpsFallbackWithoutBle',
    ),
    locationFreshnessMs: clampNumberFromSchema(
      gameConfig.locationFreshnessMs,
      'locationFreshnessMs',
    ),
  };
}
