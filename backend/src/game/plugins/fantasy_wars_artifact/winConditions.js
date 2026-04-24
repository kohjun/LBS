'use strict';

export function getControlPointWinThreshold(config = {}) {
  const controlPointCount = config.controlPointCount ?? 5;
  const winByMajority = config.winByMajority ?? false;
  return winByMajority ? 1 : Math.floor(controlPointCount / 2) + 1;
}

export function getControlPointCounts(ps = {}) {
  const guildIds = Object.keys(ps.guilds ?? {});
  const counts = Object.fromEntries(guildIds.map((guildId) => [guildId, 0]));

  (ps.controlPoints ?? []).forEach((controlPoint) => {
    if (controlPoint.capturedBy && counts[controlPoint.capturedBy] !== undefined) {
      counts[controlPoint.capturedBy] += 1;
    }
  });

  return counts;
}

export function getMajorityLeader(ps, config = {}) {
  const counts = getControlPointCounts(ps);
  const threshold = getControlPointWinThreshold(config);
  const winner = Object.keys(counts).find((guildId) => counts[guildId] >= threshold) ?? null;

  if (!winner) {
    return null;
  }

  return { winner, threshold, counts };
}

export function syncPendingMajorityVictory(gameState, config = {}, now = Date.now()) {
  const ps = gameState.pluginState ?? {};
  const holdDurationSec = config.controlPointHoldDurationSec ?? 20;
  const holdDurationMs = Math.max(0, holdDurationSec * 1000);
  const leader = getMajorityLeader(ps, config);
  const currentPending = ps.pendingVictory ?? null;

  if (!leader || holdDurationMs <= 0) {
    ps.pendingVictory = null;
    return null;
  }

  if (
    currentPending?.reason === 'control_point_majority'
    && currentPending.winner === leader.winner
  ) {
    return currentPending;
  }

  const pendingVictory = {
    winner: leader.winner,
    reason: 'control_point_majority',
    holdStartedAt: now,
    holdUntil: now + holdDurationMs,
    threshold: leader.threshold,
  };
  ps.pendingVictory = pendingVictory;
  return pendingVictory;
}

export function checkWinCondition(gameState, config = {}) {
  const ps = gameState.pluginState ?? {};
  if (!ps.guilds || !ps.controlPoints) {
    return null;
  }

  const winByMasterElim = config.winByMasterElim ?? true;
  const guildIds = Object.keys(ps.guilds);
  const holdDurationMs = Math.max(0, (config.controlPointHoldDurationSec ?? 20) * 1000);
  const leader = getMajorityLeader(ps, config);
  const pendingVictory = ps.pendingVictory ?? null;

  if (leader) {
    if (holdDurationMs <= 0) {
      return {
        winner: leader.winner,
        reason: 'control_point_majority',
        threshold: leader.threshold,
      };
    }

    if (
      pendingVictory?.reason === 'control_point_majority'
      && pendingVictory.winner === leader.winner
      && typeof pendingVictory.holdUntil === 'number'
      && pendingVictory.holdUntil <= Date.now()
    ) {
      return {
        winner: leader.winner,
        reason: 'control_point_majority',
        threshold: leader.threshold,
        holdStartedAt: pendingVictory.holdStartedAt ?? null,
        holdUntil: pendingVictory.holdUntil,
      };
    }
  }

  if (winByMasterElim) {
    const eliminated = new Set(ps.eliminatedPlayerIds ?? []);
    const aliveGuilds = guildIds.filter((guildId) => {
      const masterId = ps.guilds[guildId]?.guildMasterId;
      return masterId && !eliminated.has(masterId);
    });

    if (aliveGuilds.length === 1) {
      ps.pendingVictory = null;
      return { winner: aliveGuilds[0], reason: 'guild_master_eliminated' };
    }

    if (aliveGuilds.length === 0 && guildIds.length > 0) {
      const winner = guildIds.reduce((best, guildId) => {
        const nextScore = ps.guilds[guildId]?.score ?? 0;
        const bestScore = ps.guilds[best]?.score ?? 0;
        return nextScore >= bestScore ? guildId : best;
      }, guildIds[0]);
      ps.pendingVictory = null;
      return { winner, reason: 'last_standing_by_score' };
    }
  }

  return null;
}
