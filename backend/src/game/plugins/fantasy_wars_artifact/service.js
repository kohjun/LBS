'use strict';

import {
  captureValidator,
  captureHoldValidator,
  pruneCaptureIntents,
  isCaptureReady,
  scheduleCaptureComplete,
  cancelCaptureTimer,
} from './capture.js';
import {
  validateSkill,
  applySkillEffect,
  activeShields,
  consumeShield,
  isExecutionArmed,
} from './skills.js';
import {
  calcReviveChance,
  scheduleDungeonRevive,
  cancelDungeonTimer,
  applyReviveSuccess,
} from './revive.js';
import { defaultConfig, resolveDuelConfig } from './schema.js';
import {
  findControlPointById,
  clearCaptureIntents,
  clearCaptureZoneForControlPoint,
  resetCaptureState,
  cancelCaptureForPlayer,
} from './captureState.js';
import { clearDuelState, resolveCombatBetweenPlayers } from './duelResolution.js';
import {
  checkWinCondition as evaluateWinCondition,
  syncPendingMajorityVictory,
} from './winConditions.js';
import * as AIDirector from '../../../ai/AIDirector.js';
import { getSessionSnapshot, haversineMeters } from '../../../services/locationService.js';

const majorityHoldTimers = new Map();

function clearMajorityHoldTimer(sessionId) {
  const timer = majorityHoldTimers.get(sessionId);
  if (timer) {
    clearTimeout(timer);
    majorityHoldTimers.delete(sessionId);
  }
}

function finalizeWin(gameState, win, io, sessionId) {
  const ps = gameState.pluginState ?? {};
  ps.winCondition = win;
  ps.pendingVictory = null;
  gameState.status = 'finished';
  gameState.finishedAt = Date.now();

  io.to(`session:${sessionId}`).emit('game:over', {
    winner: win.winner,
    reason: win.reason,
  });

  AIDirector.fwOnGameEnd(
    { roomId: sessionId, pluginState: ps },
    win.winner,
    win.reason ?? 'territory',
  ).then((message) => {
    if (message) {
      io.to(`session:${sessionId}`).emit('game:ai_message', {
        type: 'announcement',
        message,
      });
    }
  }).catch(() => {});
}

function scheduleMajorityHoldTimer({ sessionId, io, readState, saveState, pendingVictory }) {
  clearMajorityHoldTimer(sessionId);
  if (!pendingVictory?.holdUntil) {
    return;
  }

  const delayMs = Math.max(0, pendingVictory.holdUntil - Date.now());
  const timer = setTimeout(async () => {
    majorityHoldTimers.delete(sessionId);

    const fresh = await readState();
    if (!fresh || fresh.status === 'finished') {
      return;
    }

    const win = checkWinCondition(fresh, cfg(fresh.pluginState ?? {}));
    if (!win || win.reason !== 'control_point_majority') {
      return;
    }

    finalizeWin(fresh, win, io, sessionId);
    await saveState(fresh);
  }, delayMs);

  majorityHoldTimers.set(sessionId, timer);
}

export function getPublicState(gameState) {
  const ps = gameState.pluginState ?? {};
  const guilds = ps.guilds ?? {};
  const config = ps._config ?? defaultConfig;
  const captureDurationMs = Math.max(1, (config.captureDurationSec ?? 30) * 1000);
  const now = Date.now();

  const guildSummary = {};
  Object.values(guilds).forEach((guild) => {
    guildSummary[guild.guildId] = {
      guildId: guild.guildId,
      displayName: guild.displayName,
      color: guild.color ?? null,
      memberIds: guild.memberIds,
      guildMasterId: guild.guildMasterId,
      score: guild.score ?? 0,
    };
  });

  const controlPoints = (ps.controlPoints ?? []).map((cp) => ({
    id: cp.id,
    displayName: cp.displayName,
    capturedBy: cp.capturedBy,
    captureProgress: cp.capturingGuild && cp.captureStartedAt
      ? Math.min(
        99,
        Math.max(
          cp.captureProgress ?? 0,
          Math.floor(((now - cp.captureStartedAt) / captureDurationMs) * 100),
        ),
      )
      : (cp.captureProgress ?? 0),
    capturingGuild: cp.capturingGuild,
    captureStartedAt: cp.captureStartedAt,
    readyCount: cp.readyCount ?? Object.keys(ps.captureIntents?.[cp.id] ?? {}).length,
    requiredCount: cp.requiredCount ?? 0,
    location: cp.location,
    blockadedBy: cp.blockadedBy,
    blockadeExpiresAt: cp.blockadeExpiresAt,
  }));

  const dungeons = (ps.dungeons ?? []).map((dungeon) => ({
    id: dungeon.id,
    displayName: dungeon.displayName,
    status: dungeon.status,
    artifact: {
      id: dungeon.artifact?.id,
      heldBy: dungeon.artifact?.heldBy,
    },
  }));

  const playableArea = Array.isArray(ps.playableArea) ? ps.playableArea : [];
  const spawnZones = (ps.spawnZones ?? []).map((zone) => ({
    teamId: zone.teamId,
    displayName: zone.displayName,
    color: zone.color ?? null,
    polygonPoints: Array.isArray(zone.polygonPoints) ? zone.polygonPoints : [],
  }));
  const duelConfig = resolveDuelConfig(config);

  return {
    status: gameState.status,
    startedAt: gameState.startedAt,
    finishedAt: gameState.finishedAt,
    duelRangeMeters: duelConfig.duelRangeMeters,
    bleEvidenceFreshnessMs: duelConfig.bleEvidenceFreshnessMs,
    allowGpsFallbackWithoutBle: duelConfig.allowGpsFallbackWithoutBle,
    aliveCount: gameState.alivePlayerIds.length,
    alivePlayerIds: gameState.alivePlayerIds,
    eliminatedPlayerIds: ps.eliminatedPlayerIds ?? [],
    guilds: guildSummary,
    controlPoints,
    dungeons,
    playableArea,
    spawnZones,
    winCondition: ps.winCondition ?? null,
  };
}

export function getPrivateState(gameState, userId) {
  const ps = gameState.pluginState ?? {};
  const player = (ps.playerStates ?? {})[userId];
  const config = ps._config ?? defaultConfig;
  if (!player) {
    return { guildId: 'unknown', job: 'warrior', isGuildMaster: false };
  }

  const dungeonEntered = Boolean(player.dungeonEnteredAt);
  const nextReviveChance = !player.isAlive && dungeonEntered
    ? calcReviveChance(
      player.reviveAttempts ?? 0,
      config.reviveBaseChance ?? 0.3,
      config.reviveStepChance ?? 0.1,
      config.reviveMaxChance ?? 0.8,
    )
    : null;

  return {
    guildId: player.guildId,
    job: player.job,
    isGuildMaster: player.isGuildMaster,
    isAlive: player.isAlive,
    hp: player.hp,
    remainingLives: player.remainingLives ?? 1,
    reviveAttempts: player.reviveAttempts,
    skillUsedAt: player.skillUsedAt ?? {},
    captureZone: player.captureZone,
    inDuel: player.inDuel ?? false,
    duelExpiresAt: player.duelExpiresAt ?? null,
    shields: activeShields(player),
    buffedUntil: player.buffedUntil ?? null,
    revealUntil: player.revealUntil ?? null,
    trackedTargetUserId: player.trackedTargetUserId ?? null,
    executionArmedUntil: player.executionArmedUntil ?? null,
    dungeonEntered,
    dungeonEnteredAt: player.dungeonEnteredAt ?? null,
    nextReviveChance,
  };
}

export function checkWinCondition(gameState, config = {}) {
  return evaluateWinCondition(gameState, config);
}

export async function handleEvent(eventName, payload, ctx) {
  switch (eventName) {
    case 'capture_start':
      return handleCaptureStart(payload, ctx);
    case 'capture_cancel':
      return handleCaptureCancel(payload, ctx);
    case 'use_skill':
      return handleUseSkill(payload, ctx);
    case 'attack':
      return { error: 'ATTACK_DISABLED_USE_DUEL' };
    case 'revive':
      return { error: 'REVIVE_DISABLED_USE_DUNGEON' };
    case 'dungeon_enter':
      return handleDungeonEnter(payload, ctx);
    default:
      return false;
  }
}

export function resolveDuelOutcome(gameState, { winnerId, loserId, reason }) {
  const ps = gameState.pluginState ?? {};
  const winner = ps.playerStates?.[winnerId];
  const loser = ps.playerStates?.[loserId];

  if (!winner || !loser) {
    return {
      verdict: { winner: winnerId, loser: loserId, reason },
      effects: {},
      eliminated: false,
    };
  }

  const resolution = resolveCombatBetweenPlayers({ winner, loser, reason });
  const { eliminated } = resolution;
  if (eliminated) {
    eliminatePlayer(loser, gameState);
  }

  return resolution;
}

function cfg(ps) {
  return ps._config ?? defaultConfig;
}

function eliminatePlayer(player, gameState) {
  clearDuelState(player);
  player.isAlive = false;
  player.hp = 0;
  player.remainingLives = 0;
  player.captureZone = null;

  const ps = gameState.pluginState ?? {};
  gameState.alivePlayerIds = gameState.alivePlayerIds.filter((id) => id !== player.userId);
  if (!(ps.eliminatedPlayerIds ?? []).includes(player.userId)) {
    ps.eliminatedPlayerIds = [...(ps.eliminatedPlayerIds ?? []), player.userId];
  }
}

async function getControlPointPresence(sessionId, ps, cp, config, requesterUserId, guildId) {
  const playerStates = ps.playerStates ?? {};
  const memberIds = Object.keys(playerStates);
  const snapshot = await getSessionSnapshot(sessionId, memberIds);
  const now = Date.now();
  const freshnessMs = config.locationFreshnessMs ?? 45_000;
  const radiusMeters = config.captureRadiusMeters ?? 30;
  const entries = [];

  memberIds.forEach((memberUserId) => {
    const player = playerStates[memberUserId];
    const location = snapshot[memberUserId];
    const isFresh = Boolean(
      location
      && typeof location.ts === 'number'
      && (now - location.ts) <= freshnessMs,
    );

    let inZone = false;
    if (isFresh && cp?.location) {
      const distance = haversineMeters(location.lat, location.lng, cp.location.lat, cp.location.lng);
      inZone = distance <= radiusMeters;
    }

    entries.push({
      userId: memberUserId,
      player,
      location: location ?? null,
      isFresh,
      inZone,
    });
  });

  const requester = entries.find((entry) => entry.userId === requesterUserId) ?? null;
  const aliveInZone = entries.filter((entry) => entry.player?.isAlive && !entry.player?.inDuel && entry.inZone);
  const friendlyInZone = aliveInZone.filter((entry) => entry.player.guildId === guildId);
  const enemyInZone = aliveInZone.filter((entry) => entry.player.guildId !== guildId);

  return {
    requester,
    friendlyInZone,
    enemyInZone,
  };
}

function setCaptureIntent(ps, controlPointId, userId, ts) {
  if (!ps.captureIntents) {
    ps.captureIntents = {};
  }
  if (!ps.captureIntents[controlPointId]) {
    ps.captureIntents[controlPointId] = {};
  }

  ps.captureIntents[controlPointId][userId] = ts;
}

function markPlayersCapturing(ps, controlPointId, participantUserIds) {
  const participantSet = new Set(participantUserIds);
  Object.values(ps.playerStates ?? {}).forEach((player) => {
    if (participantSet.has(player.userId)) {
      player.captureZone = controlPointId;
    }
  });
}

function broadcastWinIfDone(gameState, io, sessionId) {
  const ps = gameState.pluginState ?? {};
  const win = checkWinCondition(gameState, cfg(ps));
  if (!win) {
    return false;
  }

  clearMajorityHoldTimer(sessionId);
  finalizeWin(gameState, win, io, sessionId);
  return true;
}

async function handleCaptureStart({ controlPointId }, ctx) {
  const { userId, sessionId, gameState, saveState, readState, io } = ctx;
  const ps = gameState.pluginState ?? {};
  const config = cfg(ps);
  const cp = findControlPointById(ps, controlPointId);
  if (!cp) {
    return { error: 'CP_NOT_FOUND' };
  }

  const player = (ps.playerStates ?? {})[userId];
  const presence = await getControlPointPresence(
    sessionId,
    ps,
    cp,
    config,
    userId,
    player?.guildId,
  );
  const timerKey = `${sessionId}:${controlPointId}`;

  if (
    player?.isAlive
    && cp.capturingGuild
    && cp.capturingGuild !== player.guildId
    && presence.requester?.isFresh
    && presence.requester?.inZone
  ) {
    cancelCaptureTimer(timerKey);
    resetCaptureState(ps, cp, controlPointId, cp.capturingGuild);
    await saveState(gameState);
    io.to(`session:${sessionId}`).emit('fw:capture_cancelled', {
      controlPointId,
      reason: 'interrupted',
      interruptedBy: player.userId,
      interruptedByGuild: player.guildId,
    });
    return true;
  }

  const check = captureValidator(cp, player, {
    hasFreshLocation: presence.requester?.isFresh ?? false,
    requesterInZone: presence.requester?.inZone ?? false,
    friendlyInZoneCount: presence.friendlyInZone.length,
    enemyInZoneCount: presence.enemyInZone.length,
  });
  if (!check.ok) {
    return { error: check.error };
  }

  if (player.captureZone && player.captureZone !== controlPointId) {
    const previousCapture = cancelCaptureForPlayer(ps, userId);
    if (previousCapture?.cancelledActiveCapture) {
      cancelCaptureTimer(`${sessionId}:${previousCapture.controlPointId}`);
    }
  }

  const readyWindowMs = config.captureReadyWindowMs ?? 5000;
  const requiredUserIds = presence.friendlyInZone.map((entry) => entry.userId);
  const now = Date.now();
  setCaptureIntent(ps, controlPointId, userId, now);
  ps.captureIntents[controlPointId] = pruneCaptureIntents(
    ps.captureIntents[controlPointId],
    requiredUserIds,
    now,
    readyWindowMs,
  );
  cp.readyCount = Object.keys(ps.captureIntents[controlPointId] ?? {}).length;
  cp.requiredCount = requiredUserIds.length;

  if (cp.capturingGuild === player.guildId) {
    await saveState(gameState);
    io.to(`session:${sessionId}`).emit('fw:capture_progress', {
      controlPointId,
      guildId: player.guildId,
      readyCount: cp.readyCount,
      requiredCount: cp.requiredCount,
      intentWindowMs: readyWindowMs,
    });
    return true;
  }

  if (!isCaptureReady(ps.captureIntents[controlPointId], requiredUserIds)) {
    await saveState(gameState);
    io.to(`session:${sessionId}`).emit('fw:capture_progress', {
      controlPointId,
      guildId: player.guildId,
      readyCount: cp.readyCount,
      requiredCount: cp.requiredCount,
      intentWindowMs: readyWindowMs,
    });
    return true;
  }

  cp.capturingGuild = player.guildId;
  cp.captureStartedAt = now;
  cp.captureProgress = 0;
  cp.readyCount = 0;
  cp.requiredCount = 0;
  cp.captureParticipantUserIds = requiredUserIds;
  markPlayersCapturing(ps, controlPointId, requiredUserIds);

  await saveState(gameState);

  io.to(`session:${sessionId}`).emit('fw:capture_started', {
    controlPointId,
    guildId: player.guildId,
    userId,
    durationSec: config.captureDurationSec,
    startedAt: cp.captureStartedAt,
  });

  const captureDurationMs = (config.captureDurationSec ?? 30) * 1000;
  const captureGuildId = player.guildId;

  scheduleCaptureComplete(timerKey, captureDurationMs, async () => {
    const fresh = await readState();
    if (!fresh) {
      return;
    }

    const freshPluginState = fresh.pluginState ?? {};
    const freshCp = (freshPluginState.controlPoints ?? []).find((point) => point.id === controlPointId);
    if (!freshCp || freshCp.capturingGuild !== captureGuildId) {
      return;
    }

    const freshPresence = await getControlPointPresence(
      sessionId,
      freshPluginState,
      freshCp,
      freshPluginState._config ?? config,
      userId,
      captureGuildId,
    );
    const holdCheck = captureHoldValidator(freshCp, {
      friendlyInZoneCount: freshPresence.friendlyInZone.length,
      enemyInZoneCount: freshPresence.enemyInZone.length,
    });
    if (!holdCheck.ok) {
      resetCaptureState(freshPluginState, freshCp, controlPointId, captureGuildId);
      await saveState(fresh);
      io.to(`session:${sessionId}`).emit('fw:capture_cancelled', {
        controlPointId,
        reason: holdCheck.error,
        interruptedByGuild: freshPresence.enemyInZone[0]?.player?.guildId ?? null,
      });
      return;
    }

    freshCp.capturedBy = captureGuildId;
    freshCp.capturingGuild = null;
    freshCp.captureProgress = 100;
    freshCp.captureStartedAt = null;
    freshCp.readyCount = 0;
    freshCp.requiredCount = 0;
    freshCp.lastCaptureAt = Date.now();
    freshCp.captureParticipantUserIds = [];

    const guild = freshPluginState.guilds?.[captureGuildId];
    if (guild) {
      guild.score = (guild.score ?? 0) + 10;
    }

    clearCaptureZoneForControlPoint(freshPluginState, controlPointId, captureGuildId);
    clearCaptureIntents(freshPluginState, controlPointId);
    const pendingVictory = syncPendingMajorityVictory(fresh, cfg(freshPluginState));

    if (pendingVictory) {
      scheduleMajorityHoldTimer({
        sessionId,
        io,
        readState,
        saveState,
        pendingVictory,
      });
    } else {
      clearMajorityHoldTimer(sessionId);
    }

    const won = broadcastWinIfDone(fresh, io, sessionId);
    await saveState(fresh);

    io.to(`session:${sessionId}`).emit('fw:capture_complete', {
      controlPointId,
      capturedBy: captureGuildId,
      newScore: guild?.score ?? 0,
    });

    if (won) {
      return;
    }

    AIDirector.fwOnCpCaptured(
      { roomId: sessionId, pluginState: fresh.pluginState ?? {} },
      captureGuildId,
      freshCp.displayName ?? controlPointId,
    ).then((message) => {
      if (message) {
        io.to(`session:${sessionId}`).emit('game:ai_message', {
          type: 'announcement',
          message,
        });
      }
    }).catch(() => {});
  });

  return true;
}

async function handleCaptureCancel({ controlPointId }, ctx) {
  const { userId, sessionId, gameState, saveState, io } = ctx;
  const ps = gameState.pluginState ?? {};
  const config = cfg(ps);
  const cp = findControlPointById(ps, controlPointId);
  if (!cp) {
    return { error: 'CP_NOT_FOUND' };
  }

  const player = (ps.playerStates ?? {})[userId];
  if (!player?.isAlive) {
    return { error: 'PLAYER_DEAD' };
  }

  const presence = await getControlPointPresence(
    sessionId,
    ps,
    cp,
    config,
    userId,
    player.guildId,
  );
  const requesterInZone = presence.requester?.inZone ?? false;
  if (!requesterInZone) {
    return { error: 'NOT_IN_CAPTURE_ZONE' };
  }

  if (cp.capturingGuild === player.guildId) {
    cancelCaptureTimer(`${sessionId}:${controlPointId}`);
    resetCaptureState(ps, cp, controlPointId, player.guildId);
  } else if (cp.capturingGuild && cp.capturingGuild !== player.guildId) {
    cancelCaptureTimer(`${sessionId}:${controlPointId}`);
    resetCaptureState(ps, cp, controlPointId, cp.capturingGuild);
  } else {
    clearCaptureIntents(ps, controlPointId);
    player.captureZone = null;
  }

  await saveState(gameState);
  io.to(`session:${sessionId}`).emit('fw:capture_cancelled', {
    controlPointId,
    userId,
    guildId: player.guildId,
  });
  return true;
}

async function handleUseSkill({ skill, targetUserId, controlPointId }, ctx) {
  const { socket, userId, sessionId, gameState, saveState, io } = ctx;
  const ps = gameState.pluginState ?? {};
  const config = cfg(ps);
  const player = (ps.playerStates ?? {})[userId];
  if (!player?.isAlive) {
    return { error: 'PLAYER_DEAD' };
  }

  const { ok, effect, error: skillError } = validateSkill(player.job, skill);
  if (!ok) {
    return { error: skillError };
  }

  const cooldownSec = config.skillCooldowns?.[player.job] ?? 0;
  const lastUsed = player.skillUsedAt?.[skill] ?? 0;
  const remaining = cooldownSec * 1000 - (Date.now() - lastUsed);
  if (remaining > 0) {
    socket.emit('fw:skill_cooldown', {
      skill,
      remainSec: Math.ceil(remaining / 1000),
    });
    return true;
  }

  const targetPlayer = targetUserId ? (ps.playerStates ?? {})[targetUserId] : null;
  const cp = controlPointId ? (ps.controlPoints ?? []).find((point) => point.id === controlPointId) : null;
  const result = applySkillEffect(effect, {
    player,
    targetPlayer,
    cp,
    now: Date.now(),
  });

  if (result === null) {
    return { error: 'SKILL_CANNOT_APPLY' };
  }
  if (result.error) {
    return { error: result.error };
  }

  if (!player.skillUsedAt) {
    player.skillUsedAt = {};
  }
  player.skillUsedAt[skill] = Date.now();

  await saveState(gameState);

  socket.emit('fw:skill_used', { skill, effect, result });
  io.to(`session:${sessionId}`).emit('fw:player_skill', {
    userId,
    skill,
    job: player.job,
    result,
  });

  return true;
}

async function handleDungeonEnter({ dungeonId = 'dungeon_main' }, ctx) {
  const { userId, sessionId, gameState, saveState, readState, io } = ctx;
  const ps = gameState.pluginState ?? {};
  const config = cfg(ps);
  const player = (ps.playerStates ?? {})[userId];

  if (!player) {
    return { error: 'PLAYER_NOT_FOUND' };
  }

  if (player.isAlive) {
    return { error: 'PLAYER_NOT_DEAD' };
  }

  if (player.dungeonEnteredAt) {
    return { error: 'ALREADY_IN_DUNGEON' };
  }

  const dungeon = (ps.dungeons ?? []).find((item) => item.id === dungeonId);
  if (!dungeon || dungeon.status !== 'open') {
    return { error: 'DUNGEON_CLOSED' };
  }

  player.dungeonEnteredAt = Date.now();
  await saveState(gameState);

  const timerKey = `${sessionId}:${userId}`;
  scheduleDungeonAttempt(timerKey, userId, sessionId, config, readState, saveState, io);

  return true;
}

function scheduleDungeonAttempt(timerKey, userId, sessionId, config, readState, saveState, io) {
  scheduleDungeonRevive(timerKey, async () => {
    const fresh = await readState();
    if (!fresh) {
      return;
    }

    const ps = fresh.pluginState ?? {};
    const currentConfig = ps._config ?? config;
    const player = ps.playerStates?.[userId];
    if (!player || player.isAlive || !player.dungeonEnteredAt) {
      return;
    }

    const chance = calcReviveChance(
      player.reviveAttempts,
      currentConfig.reviveBaseChance ?? 0.3,
      currentConfig.reviveStepChance ?? 0.1,
      currentConfig.reviveMaxChance ?? 0.8,
    );
    player.reviveAttempts += 1;

    if (Math.random() < chance) {
      applyReviveSuccess(player, fresh);
      await saveState(fresh);
      cancelDungeonTimer(timerKey);
      io.to(`session:${sessionId}`).emit('fw:player_revived', {
        targetUserId: userId,
        revivedBy: 'dungeon',
      });
      return;
    }

    await saveState(fresh);
    io.to(`session:${sessionId}`).emit('fw:revive_failed', {
      targetUserId: userId,
      attemptedBy: 'dungeon',
      nextChance: calcReviveChance(
        player.reviveAttempts,
        currentConfig.reviveBaseChance ?? 0.3,
        currentConfig.reviveStepChance ?? 0.1,
        currentConfig.reviveMaxChance ?? 0.8,
      ),
    });

    if (player.dungeonEnteredAt) {
      scheduleDungeonAttempt(timerKey, userId, sessionId, currentConfig, readState, saveState, io);
    }
  });
}
