import test from 'node:test';
import assert from 'node:assert/strict';

import {
  calcReviveChance,
  applyReviveSuccess,
} from '../../src/game/plugins/fantasy_wars_artifact/revive.js';
import { makeGameState, makePlayer } from '../../testing/fantasy_wars/helpers.js';

test('calcReviveChance uses base chance, increases by step, and caps at 0.8 by default', () => {
  assert.equal(calcReviveChance(0, 0.3, 0.1), 0.3);
  assert.equal(calcReviveChance(2, 0.3, 0.1), 0.5);
  assert.equal(calcReviveChance(20, 0.3, 0.1), 0.8);
  assert.equal(calcReviveChance(20, 0.3, 0.1, 0.7), 0.7);
});

test('applyReviveSuccess restores warrior state and removes elimination markers', () => {
  const player = makePlayer({
    userId: 'user-warrior',
    job: 'warrior',
    isAlive: false,
    hp: 0,
    remainingLives: 0,
    reviveAttempts: 3,
    dungeonEnteredAt: 1234,
    inDuel: true,
    duelExpiresAt: 5678,
  });
  const gameState = makeGameState({
    alivePlayerIds: ['user-other'],
    pluginState: {
      eliminatedPlayerIds: ['user-warrior', 'user-other'],
    },
  });

  applyReviveSuccess(player, gameState);

  assert.equal(player.isAlive, true);
  assert.equal(player.hp, 100);
  assert.equal(player.reviveAttempts, 0);
  assert.equal(player.remainingLives, 2);
  assert.equal(player.dungeonEnteredAt, null);
  assert.equal(player.inDuel, false);
  assert.equal(player.duelExpiresAt, null);
  assert.deepEqual(gameState.alivePlayerIds, ['user-other', 'user-warrior']);
  assert.deepEqual(gameState.pluginState.eliminatedPlayerIds, ['user-other']);
});

test('applyReviveSuccess restores non-warrior with one life', () => {
  const player = makePlayer({
    userId: 'user-priest',
    job: 'priest',
    isAlive: false,
    remainingLives: 0,
  });
  const gameState = makeGameState();

  applyReviveSuccess(player, gameState);

  assert.equal(player.remainingLives, 1);
  assert.deepEqual(gameState.alivePlayerIds, ['user-priest']);
});
