'use strict';

// ─────────────────────────────────────────────────────────────────────────────
// Revive — dungeon periodic revive timer management + chance calculator
// ─────────────────────────────────────────────────────────────────────────────

const DUNGEON_REVIVE_INTERVAL_MS = 60_000;

// Module-level map: `${sessionId}:${userId}` → timeoutId
const dungeonTimers = new Map();

// ── calcReviveChance ──────────────────────────────────────────────────────────
// Pure: base + step * attempts, capped at reviveMaxChance.
export function calcReviveChance(reviveAttempts, baseChance, stepChance, maxChance = 0.8) {
  return Math.min(maxChance, baseChance + reviveAttempts * stepChance);
}

// ── scheduleDungeonRevive ─────────────────────────────────────────────────────
// Schedules a single revive attempt after DUNGEON_REVIVE_INTERVAL_MS.
// onAttempt will be called with no args.
export function scheduleDungeonRevive(key, onAttempt) {
  cancelDungeonTimer(key);
  const id = setTimeout(onAttempt, DUNGEON_REVIVE_INTERVAL_MS);
  dungeonTimers.set(key, id);
}

export function cancelDungeonTimer(key) {
  const id = dungeonTimers.get(key);
  if (id !== undefined) {
    clearTimeout(id);
    dungeonTimers.delete(key);
  }
}

// ── applyReviveSuccess ────────────────────────────────────────────────────────
// Mutates player + gameState to restore player to alive state.
export function applyReviveSuccess(player, gameState) {
  player.isAlive          = true;
  player.hp               = 100;
  player.reviveAttempts   = 0;
  player.remainingLives   = player.job === 'warrior' ? 2 : 1;
  player.dungeonEnteredAt = null;
  player.inDuel           = false;
  player.duelExpiresAt    = null;

  const ps = gameState.pluginState;
  if (!gameState.alivePlayerIds.includes(player.userId)) {
    gameState.alivePlayerIds = [...gameState.alivePlayerIds, player.userId];
  }
  ps.eliminatedPlayerIds = (ps.eliminatedPlayerIds ?? []).filter(id => id !== player.userId);
}
