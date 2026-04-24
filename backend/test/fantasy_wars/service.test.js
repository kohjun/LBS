import test from 'node:test';
import assert from 'node:assert/strict';

import { defaultConfig } from '../../src/game/plugins/fantasy_wars_artifact/schema.js';
import { getPublicState } from '../../src/game/plugins/fantasy_wars_artifact/service.js';
import { checkWinCondition } from '../../src/game/plugins/fantasy_wars_artifact/winConditions.js';
import { makeControlPoint, makeGameState } from '../../testing/fantasy_wars/helpers.js';

function makeGuilds() {
  return {
    guild_alpha: {
      guildId: 'guild_alpha',
      guildMasterId: 'alpha-master',
      score: 10,
    },
    guild_beta: {
      guildId: 'guild_beta',
      guildMasterId: 'beta-master',
      score: 5,
    },
    guild_gamma: {
      guildId: 'guild_gamma',
      guildMasterId: 'gamma-master',
      score: 3,
    },
  };
}

test('checkWinCondition waits for the control point hold duration before territory win', () => {
  const gameState = makeGameState({
    pluginState: {
      guilds: makeGuilds(),
      controlPoints: [
        makeControlPoint({ id: 'cp-1', capturedBy: 'guild_alpha' }),
        makeControlPoint({ id: 'cp-2', capturedBy: 'guild_alpha' }),
        makeControlPoint({ id: 'cp-3', capturedBy: 'guild_alpha' }),
        makeControlPoint({ id: 'cp-4', capturedBy: 'guild_beta' }),
        makeControlPoint({ id: 'cp-5' }),
      ],
      pendingVictory: {
        winner: 'guild_alpha',
        reason: 'control_point_majority',
        holdStartedAt: Date.now() - 5_000,
        holdUntil: Date.now() + 10_000,
      },
    },
  });

  assert.equal(checkWinCondition(gameState, defaultConfig), null);
});

test('checkWinCondition grants territory win after the hold timer expires', () => {
  const now = Date.now();
  const gameState = makeGameState({
    pluginState: {
      guilds: makeGuilds(),
      controlPoints: [
        makeControlPoint({ id: 'cp-1', capturedBy: 'guild_alpha' }),
        makeControlPoint({ id: 'cp-2', capturedBy: 'guild_alpha' }),
        makeControlPoint({ id: 'cp-3', capturedBy: 'guild_alpha' }),
        makeControlPoint({ id: 'cp-4', capturedBy: 'guild_beta' }),
        makeControlPoint({ id: 'cp-5' }),
      ],
      pendingVictory: {
        winner: 'guild_alpha',
        reason: 'control_point_majority',
        holdStartedAt: now - 25_000,
        holdUntil: now - 5_000,
      },
    },
  });

  const verdict = checkWinCondition(gameState, defaultConfig);
  assert.equal(verdict?.winner, 'guild_alpha');
  assert.equal(verdict?.reason, 'control_point_majority');
});

test('checkWinCondition still allows immediate guild master elimination wins', () => {
  const gameState = makeGameState({
    pluginState: {
      guilds: makeGuilds(),
      controlPoints: [
        makeControlPoint({ id: 'cp-1', capturedBy: 'guild_alpha' }),
        makeControlPoint({ id: 'cp-2', capturedBy: 'guild_beta' }),
      ],
      eliminatedPlayerIds: ['beta-master', 'gamma-master'],
      pendingVictory: {
        winner: 'guild_alpha',
        reason: 'control_point_majority',
        holdStartedAt: Date.now(),
        holdUntil: Date.now() + 20_000,
      },
    },
  });

  const verdict = checkWinCondition(gameState, defaultConfig);
  assert.equal(verdict?.winner, 'guild_alpha');
  assert.equal(verdict?.reason, 'guild_master_eliminated');
});

test('getPublicState exposes duel BLE rules to clients', () => {
  const gameState = makeGameState({
    pluginState: {
      guilds: makeGuilds(),
      controlPoints: [],
      dungeons: [],
      playableArea: [],
      spawnZones: [],
      _config: {
        ...defaultConfig,
        duelRangeMeters: 18,
        bleEvidenceFreshnessMs: 9000,
        allowGpsFallbackWithoutBle: false,
      },
    },
    alivePlayerIds: ['alpha-master'],
  });

  const publicState = getPublicState(gameState);
  assert.equal(publicState.duelRangeMeters, 18);
  assert.equal(publicState.bleEvidenceFreshnessMs, 9000);
  assert.equal(publicState.allowGpsFallbackWithoutBle, false);
});
