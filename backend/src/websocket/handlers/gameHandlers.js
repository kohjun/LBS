import { GamePluginRegistry } from '../../game/index.js';
import { startGameForSession } from '../../game/startGameService.js';
import { EVENTS } from '../socketProtocol.js';
import { readGameState, saveGameState } from '../socketRuntime.js';
import { duelService } from '../../game/duel/DuelService.js';
import { SocketTransportAdapter } from '../../game/duel/TransportAdapter.js';
import { resolveDuelConfig } from '../../game/plugins/fantasy_wars_artifact/schema.js';
import {
  getPairProximityEvidence,
  recordProximityPayload,
} from '../../game/duel/ProximityEvidence.js';
import * as AIDirector from '../../ai/AIDirector.js';
import { getSessionSnapshot, haversineMeters } from '../../services/locationService.js';
import { cancelCaptureForPlayer } from '../../game/plugins/fantasy_wars_artifact/captureState.js';

async function loadPluginCtx(sessionId) {
  const gameState = await readGameState(sessionId);
  if (!gameState) {
    return null;
  }

  const plugin = GamePluginRegistry.get(gameState.gameType ?? 'among_us');
  return { gameState, plugin };
}

function emitPluginStateUpdate(io, sessionId, gameState, plugin, userIds = []) {
  const publicState = plugin.getPublicState?.(gameState) ?? {};
  io.to(`session:${sessionId}`).emit(EVENTS.GAME_STATE_UPDATE, {
    sessionId,
    gameType: gameState.gameType,
    ...publicState,
  });

  for (const targetUserId of [...new Set(userIds.filter(Boolean))]) {
    const privateState = plugin.getPrivateState?.(gameState, targetUserId) ?? {};
    io.to(`user:${targetUserId}`).emit(EVENTS.GAME_STATE_UPDATE, {
      sessionId,
      gameType: gameState.gameType,
      ...publicState,
      ...privateState,
    });
  }
}

function getFantasyWarsPlayerLabel(gameState, userId) {
  if (!userId) {
    return 'unknown player';
  }
  const nickname = gameState?.pluginState?.playerStates?.[userId]?.nickname;
  return nickname || userId;
}

function buildFantasyWarsDuelLog(gameState, {
  stage,
  duelId,
  challengerId,
  targetId,
  winnerId,
  loserId,
  minigameType,
  reason,
}) {
  const challengerLabel = getFantasyWarsPlayerLabel(gameState, challengerId);
  const targetLabel = getFantasyWarsPlayerLabel(gameState, targetId);
  const winnerLabel = getFantasyWarsPlayerLabel(gameState, winnerId);
  const loserLabel = getFantasyWarsPlayerLabel(gameState, loserId);

  let message = `Duel | ${stage}`;
  switch (stage) {
    case 'challenged':
      message = `Duel challenged | ${challengerLabel} vs ${targetLabel}`;
      break;
    case 'started':
      message =
        `Duel started | ${challengerLabel} vs ${targetLabel}` +
        (minigameType ? ` | ${minigameType}` : '');
      break;
    case 'rejected':
      message = `Duel rejected | ${challengerLabel} vs ${targetLabel}`;
      break;
    case 'cancelled':
      message = `Duel cancelled | ${challengerLabel} vs ${targetLabel}`;
      break;
    case 'invalidated':
      message =
        `Duel invalidated | ${challengerLabel} vs ${targetLabel}` +
        (reason ? ` | ${reason}` : '');
      break;
    case 'resolved':
      message = winnerId && loserId
        ? `Duel resolved | ${winnerLabel} beat ${loserLabel}` +
            (reason ? ` | ${reason}` : '')
        : `Duel resolved | draw` + (reason ? ` | ${reason}` : '');
      break;
  }

  return {
    kind: 'duel',
    stage,
    duelId,
    challengerId,
    targetId,
    winnerId,
    loserId,
    minigameType: minigameType ?? null,
    reason: reason ?? null,
    message,
    recordedAt: Date.now(),
  };
}

function emitFantasyWarsDuelLog(io, sessionId, payload) {
  io.to(`session:${sessionId}`).emit(EVENTS.FW_DUEL_LOG, payload);
}

function buildProximityDebugPayload(proximity, now) {
  const freshestReport = proximity.reports?.[0] ?? null;
  return {
    proximitySource: proximity.bestSource,
    bleConfirmed: proximity.bestSource === 'ble',
    gpsFallbackUsed: proximity.bestSource === 'gps_fallback',
    mutualProximity: proximity.mutual,
    recentProximityReports: proximity.reports?.length ?? 0,
    freshestEvidenceAgeMs:
      freshestReport && typeof freshestReport.seenAt === 'number'
        ? Math.max(0, Math.round(now - freshestReport.seenAt))
        : null,
  };
}

async function validateFantasyWarsDuelPair(sessionId, challengerId, targetId) {
  const gameState = await readGameState(sessionId);
  if (!gameState) {
    return { ok: false, error: 'GAME_NOT_STARTED' };
  }

  const ps = gameState.pluginState ?? {};
  const challenger = ps.playerStates?.[challengerId];
  const target = ps.playerStates?.[targetId];
  if (!challenger || !target) {
    return { ok: false, error: 'PLAYER_NOT_IN_SESSION' };
  }
  if (!challenger.isAlive || !target.isAlive) {
    return { ok: false, error: 'PLAYER_DEAD' };
  }
  if (challenger.guildId === target.guildId) {
    return { ok: false, error: 'TARGET_NOT_ENEMY' };
  }

  const config = ps._config ?? {};
  const duelConfig = resolveDuelConfig(config);
  const freshnessMs = duelConfig.locationFreshnessMs;
  const duelRangeMeters = duelConfig.duelRangeMeters;
  const bleEvidenceFreshnessMs = duelConfig.bleEvidenceFreshnessMs;
  const allowGpsFallbackWithoutBle = duelConfig.allowGpsFallbackWithoutBle;
  const now = Date.now();
  const snapshot = await getSessionSnapshot(sessionId, [challengerId, targetId]);
  const challengerLocation = snapshot[challengerId];
  const targetLocation = snapshot[targetId];

  if (!challengerLocation || !targetLocation) {
    return { ok: false, error: 'LOCATION_UNAVAILABLE' };
  }
  if (
    typeof challengerLocation.ts !== 'number'
    || typeof targetLocation.ts !== 'number'
    || (now - challengerLocation.ts) > freshnessMs
    || (now - targetLocation.ts) > freshnessMs
  ) {
    return { ok: false, error: 'LOCATION_STALE' };
  }

  const distanceMeters = haversineMeters(
    challengerLocation.lat,
    challengerLocation.lng,
    targetLocation.lat,
    targetLocation.lng,
  );
  if (distanceMeters > duelRangeMeters) {
    return {
      ok: false,
      error: 'TARGET_OUT_OF_RANGE',
      distanceMeters: Math.round(distanceMeters),
      duelRangeMeters,
    };
  }

  const proximity = getPairProximityEvidence(
    sessionId,
    challengerId,
    targetId,
    {
      freshnessMs: bleEvidenceFreshnessMs,
      now,
    },
  );
  const proximityDebug = buildProximityDebugPayload(proximity, now);
  const { bleConfirmed, gpsFallbackUsed } = proximityDebug;
  if (!bleConfirmed && !(allowGpsFallbackWithoutBle && gpsFallbackUsed)) {
    return {
      ok: false,
      error: 'BLE_PROXIMITY_REQUIRED',
      distanceMeters: Math.round(distanceMeters),
      duelRangeMeters,
      bleEvidenceFreshnessMs,
      allowGpsFallbackWithoutBle,
      ...proximityDebug,
    };
  }

  return {
    ok: true,
    gameState,
    challenger,
    target,
    distanceMeters: Math.round(distanceMeters),
    duelRangeMeters,
    bleEvidenceFreshnessMs,
    allowGpsFallbackWithoutBle,
    ...proximityDebug,
  };
}

async function setDuelLockState(io, sessionId, participantIds, enabled, duelExpiresAt = null) {
  const gameState = await readGameState(sessionId);
  if (!gameState) {
    return null;
  }

  const plugin = GamePluginRegistry.get(gameState.gameType ?? 'fantasy_wars_artifact');
  const ps = gameState.pluginState ?? {};
  const cancelledControlPointIds = new Set();
  participantIds.forEach((participantId) => {
    const player = ps.playerStates?.[participantId];
    if (!player) {
      return;
    }

    if (enabled && player.captureZone) {
      const capture = cancelCaptureForPlayer(ps, participantId);
      if (capture?.cancelledActiveCapture) {
        cancelledControlPointIds.add(capture.controlPointId);
      }
    }

    player.inDuel = enabled;
    player.duelExpiresAt = enabled ? duelExpiresAt : null;
  });

  await saveGameState(sessionId, gameState);
  emitPluginStateUpdate(io, sessionId, gameState, plugin, participantIds);
  if (enabled && cancelledControlPointIds.size > 0) {
    const { cancelCaptureTimer } = await import('../../game/plugins/fantasy_wars_artifact/capture.js');
    cancelledControlPointIds.forEach((controlPointId) => {
      cancelCaptureTimer(`${sessionId}:${controlPointId}`);
      io.to(`session:${sessionId}`).emit(EVENTS.FW_CAPTURE_CANCELLED, {
        controlPointId,
        reason: 'participant_entered_duel',
      });
    });
  }
  return { gameState, plugin };
}

export const registerGameHandlers = ({ io, socket, mediaServer, userId }) => {
  socket.on(EVENTS.GAME_START, async ({ sessionId: sid } = {}) => {
    const sessionId = sid || socket.currentSessionId;
    if (!sessionId) {
      return;
    }

    try {
      await startGameForSession({ io, sessionId, requesterUserId: userId });
    } catch (err) {
      console.error('[WS] game:start error:', err);
      socket.emit(EVENTS.ERROR, {
        code: err.message || 'GAME_START_FAILED',
        ...(err.details ?? {}),
      });
    }
  });

  socket.on(EVENTS.GAME_REQUEST_STATE, async ({ sessionId: sid } = {}) => {
    const sessionId = sid || socket.currentSessionId;
    if (!sessionId) {
      return;
    }

    try {
      const ctx = await loadPluginCtx(sessionId);
      if (!ctx) {
        socket.emit(EVENTS.GAME_STATE_UPDATE, { sessionId, status: 'none' });
        return;
      }

      const { gameState, plugin } = ctx;
      const publicState = plugin.getPublicState?.(gameState) ?? {};
      const privateState = plugin.getPrivateState?.(gameState, userId) ?? {};
      socket.emit(EVENTS.GAME_STATE_UPDATE, {
        sessionId,
        gameType: gameState.gameType,
        ...publicState,
        ...privateState,
      });
    } catch (err) {
      console.error('[WS] game:request_state error:', err);
    }
  });

  const dispatch = (eventName, { requireGame = true } = {}) =>
    async (payload, cb) => {
      const sessionId = payload?.sessionId || socket.currentSessionId;
      const respond = typeof cb === 'function' ? cb : () => {};
      if (!sessionId) {
        respond({ ok: false, error: 'MISSING_SESSION_ID' });
        return;
      }

      try {
        const ctx = await loadPluginCtx(sessionId);
        if (!ctx) {
          if (requireGame) {
            respond({ ok: false, error: 'GAME_NOT_STARTED' });
          }
          return;
        }

        const { gameState, plugin } = ctx;
        const result = await plugin.handleEvent(eventName, payload ?? {}, {
          io,
          socket,
          userId,
          sessionId,
          gameState,
          saveState: (gs) => saveGameState(sessionId, gs),
          readState: () => readGameState(sessionId),
          mediaServer,
        });

        if (result && typeof result === 'object' && result.error) {
          respond({ ok: false, error: result.error });
        } else if (result === false) {
          respond({ ok: false, error: 'ACTION_REJECTED' });
        } else if (result && typeof result === 'object') {
          respond({ ok: true, ...result });
        } else {
          respond({ ok: true });
        }
      } catch (err) {
        console.error(`[WS] ${eventName} error:`, err);
        respond({ ok: false, error: err.message });
      }
    };

  socket.on(EVENTS.GAME_KILL, dispatch('kill'));
  socket.on(EVENTS.GAME_EMERGENCY, dispatch('emergency'));
  socket.on(EVENTS.GAME_REPORT, dispatch('report'));
  socket.on(EVENTS.GAME_VOTE, dispatch('vote'));
  socket.on(EVENTS.GAME_MISSION_DONE, dispatch('mission_complete'));
  socket.on(EVENTS.GAME_TRIGGER_SABOTAGE, dispatch('trigger_sabotage'));
  socket.on(EVENTS.GAME_FIX_SABOTAGE, dispatch('fix_sabotage'));

  socket.on(EVENTS.FW_CAPTURE_START, dispatch('capture_start'));
  socket.on(EVENTS.FW_CAPTURE_CANCEL, dispatch('capture_cancel'));
  socket.on(EVENTS.FW_USE_SKILL, dispatch('use_skill'));
  socket.on(EVENTS.FW_ATTACK, dispatch('attack'));
  socket.on(EVENTS.FW_REVIVE, dispatch('revive'));
  socket.on(EVENTS.FW_DUNGEON_ENTER, dispatch('dungeon_enter'));

  socket.on(EVENTS.CALL_MEETING, dispatch('emergency'));
  socket.on(EVENTS.SUBMIT_VOTE, dispatch('vote'));

  const transport = new SocketTransportAdapter(io);

  const onDuelResolve = async ({ duelId, winnerId, loserId, sessionId: sid, reason, minigameType }) => {
    if (!winnerId || !loserId) {
      const logState = await readGameState(sid);
      emitFantasyWarsDuelLog(
        io,
        sid,
        buildFantasyWarsDuelLog(logState, {
          stage: 'resolved',
          duelId,
          winnerId,
          loserId,
          minigameType,
          reason,
        }),
      );
      AIDirector.fwOnDuelDraw({ roomId: sid }, minigameType ?? '?').then((message) => {
        if (message) {
          io.to(`session:${sid}`).emit('game:ai_message', {
            type: 'announcement',
            message,
          });
        }
      }).catch(() => {});
      return null;
    }

    const gs = await readGameState(sid);
    if (!gs) {
      return null;
    }

    const plugin = GamePluginRegistry.get(gs.gameType ?? 'fantasy_wars_artifact');
    const ps = gs.pluginState ?? {};
    const loser = ps.playerStates?.[loserId];
    const winner = ps.playerStates?.[winnerId];
    if (!loser || !winner) {
      return null;
    }

    if (loser.captureZone) {
      const activeCaptureId = loser.captureZone;
      const capture = cancelCaptureForPlayer(ps, loserId);
      if (capture?.cancelledActiveCapture) {
        const { cancelCaptureTimer } = await import('../../game/plugins/fantasy_wars_artifact/capture.js');
        cancelCaptureTimer(`${sid}:${activeCaptureId}`);
      }
    }

    const resolution = plugin.resolveDuelOutcome?.(gs, {
      winnerId,
      loserId,
      reason,
      minigameType,
    }) ?? {
      verdict: { winner: winnerId, loser: loserId, reason },
      effects: {},
      eliminated: false,
    };
    const resolvedWinnerId = resolution?.verdict?.winner ?? winnerId;
    const resolvedLoserId = resolution?.verdict?.loser ?? loserId;
    const resolvedReason = resolution?.verdict?.reason ?? reason;

    const win = plugin.checkWinCondition?.(gs);
    if (win) {
      ps.winCondition = win;
      gs.status = 'finished';
      gs.finishedAt = Date.now();
    }

    await saveGameState(sid, gs);
    emitPluginStateUpdate(io, sid, gs, plugin, [winnerId, loserId]);
    emitFantasyWarsDuelLog(
      io,
      sid,
      buildFantasyWarsDuelLog(gs, {
        stage: 'resolved',
        duelId,
        challengerId: resolvedWinnerId,
        targetId: resolvedLoserId,
        winnerId: resolvedWinnerId,
        loserId: resolvedLoserId,
        minigameType,
        reason: resolvedReason,
      }),
    );

    if (resolution.eliminated) {
      io.to(`session:${sid}`).emit('fw:player_eliminated', {
        userId: loserId,
        killedBy: winnerId,
        method: 'duel',
        duelReason: reason,
      });
    }

    if (win) {
      io.to(`session:${sid}`).emit('game:over', {
        winner: win.winner,
        reason: win.reason,
      });
      AIDirector.fwOnGameEnd(
        { roomId: sid, pluginState: ps },
        win.winner,
        win.reason ?? 'territory',
      ).then((message) => {
        if (message) {
          io.to(`session:${sid}`).emit('game:ai_message', {
            type: 'announcement',
            message,
          });
        }
      }).catch(() => {});
    } else {
      AIDirector.fwOnDuelResult(
        { roomId: sid, pluginState: ps },
        { userId: winnerId, nickname: winner.nickname ?? winnerId },
        { userId: loserId, nickname: loser.nickname ?? loserId },
        minigameType ?? '?',
        resolution.effects?.executionTriggered === true,
      ).then((message) => {
        if (message) {
          io.to(`session:${sid}`).emit('game:ai_message', {
            type: 'announcement',
            message,
          });
        }
      }).catch(() => {});
    }

    return resolution;
  };

  socket.on(EVENTS.FW_DUEL_CHALLENGE, async (payload, cb) => {
    const respond = typeof cb === 'function' ? cb : () => {};
    const sessionId = payload?.sessionId || socket.currentSessionId;
    const targetId = payload?.targetUserId;
    if (!sessionId || !targetId) {
      respond({ ok: false, error: 'MISSING_FIELDS' });
      return;
    }

    recordProximityPayload({
      sessionId,
      observerId: userId,
      expectedTargetId: targetId,
      proximity: payload?.proximity,
    });

    const validation = await validateFantasyWarsDuelPair(sessionId, userId, targetId);
    if (!validation.ok) {
      respond(validation);
      return;
    }

    const result = duelService.challenge({
      challengerId: userId,
      targetId,
      sessionId,
      transport,
      onResolve: (args) => onDuelResolve({ ...args, sessionId }),
      onInvalidate: async (args) => {
        const logState = await readGameState(sessionId);
        emitFantasyWarsDuelLog(
          io,
          sessionId,
          buildFantasyWarsDuelLog(logState, {
            stage: 'invalidated',
            duelId: args.duelId,
            challengerId: args.challengerId,
            targetId: args.targetId,
            reason: args.reason,
          }),
        );
      },
    });
    if (result.ok) {
      const logState = await readGameState(sessionId);
      emitFantasyWarsDuelLog(
        io,
        sessionId,
        buildFantasyWarsDuelLog(logState, {
          stage: 'challenged',
          duelId: result.duelId,
          challengerId: userId,
          targetId,
        }),
      );
    }
    respond({
      ...result,
      distanceMeters: validation.distanceMeters,
      proximitySource: validation.proximitySource,
      bleConfirmed: validation.bleConfirmed,
      gpsFallbackUsed: validation.gpsFallbackUsed,
      mutualProximity: validation.mutualProximity,
      recentProximityReports: validation.recentProximityReports,
      freshestEvidenceAgeMs: validation.freshestEvidenceAgeMs,
      duelRangeMeters: validation.duelRangeMeters,
      bleEvidenceFreshnessMs: validation.bleEvidenceFreshnessMs,
      allowGpsFallbackWithoutBle: validation.allowGpsFallbackWithoutBle,
    });
  });

  socket.on(EVENTS.FW_DUEL_ACCEPT, async (payload, cb) => {
    const respond = typeof cb === 'function' ? cb : () => {};
    const { duelId } = payload ?? {};
    if (!duelId) {
      respond({ ok: false, error: 'MISSING_DUEL_ID' });
      return;
    }

    const duel = duelService.getDuel(duelId);
    if (!duel) {
      respond({ ok: false, error: 'DUEL_NOT_PENDING' });
      return;
    }

    recordProximityPayload({
      sessionId: duel.sessionId,
      observerId: userId,
      expectedTargetId: duel.challengerId,
      proximity: payload?.proximity,
    });

    const validation = await validateFantasyWarsDuelPair(
      duel.sessionId,
      duel.challengerId,
      duel.targetId,
    );
    if (!validation.ok) {
      duelService.invalidate(duelId, validation.error);
      respond(validation);
      return;
    }

    const result = duelService.accept({ duelId, userId });
    if (result.ok) {
      await setDuelLockState(
        io,
        duel.sessionId,
        [duel.challengerId, duel.targetId],
        true,
        (result.startedAt ?? Date.now()) + (result.gameTimeoutMs ?? 30_000),
      );
      const logState = await readGameState(duel.sessionId);
      emitFantasyWarsDuelLog(
        io,
        duel.sessionId,
        buildFantasyWarsDuelLog(logState, {
          stage: 'started',
          duelId,
          challengerId: duel.challengerId,
          targetId: duel.targetId,
          minigameType: duel.minigameType,
        }),
      );
    }
    respond({
      ...result,
      distanceMeters: validation.distanceMeters,
      proximitySource: validation.proximitySource,
      bleConfirmed: validation.bleConfirmed,
      gpsFallbackUsed: validation.gpsFallbackUsed,
      mutualProximity: validation.mutualProximity,
      recentProximityReports: validation.recentProximityReports,
      freshestEvidenceAgeMs: validation.freshestEvidenceAgeMs,
      duelRangeMeters: validation.duelRangeMeters,
      bleEvidenceFreshnessMs: validation.bleEvidenceFreshnessMs,
      allowGpsFallbackWithoutBle: validation.allowGpsFallbackWithoutBle,
    });
  });

  socket.on(EVENTS.FW_DUEL_REJECT, async (payload, cb) => {
    const respond = typeof cb === 'function' ? cb : () => {};
    const { duelId } = payload ?? {};
    if (!duelId) {
      respond({ ok: false, error: 'MISSING_DUEL_ID' });
      return;
    }
    const duel = duelService.getDuel(duelId);
    const result = duelService.reject({ duelId, userId });
    if (result.ok && duel) {
      const logState = await readGameState(duel.sessionId);
      emitFantasyWarsDuelLog(
        io,
        duel.sessionId,
        buildFantasyWarsDuelLog(logState, {
          stage: 'rejected',
          duelId,
          challengerId: duel.challengerId,
          targetId: duel.targetId,
        }),
      );
    }
    respond(result);
  });

  socket.on(EVENTS.FW_DUEL_CANCEL, async (payload, cb) => {
    const respond = typeof cb === 'function' ? cb : () => {};
    const { duelId } = payload ?? {};
    if (!duelId) {
      respond({ ok: false, error: 'MISSING_DUEL_ID' });
      return;
    }
    const duel = duelService.getDuel(duelId);
    const result = duelService.cancel({ duelId, userId });
    if (result.ok && duel) {
      const logState = await readGameState(duel.sessionId);
      emitFantasyWarsDuelLog(
        io,
        duel.sessionId,
        buildFantasyWarsDuelLog(logState, {
          stage: 'cancelled',
          duelId,
          challengerId: duel.challengerId,
          targetId: duel.targetId,
        }),
      );
    }
    respond(result);
  });

  socket.on(EVENTS.FW_DUEL_SUBMIT, async (payload, cb) => {
    const respond = typeof cb === 'function' ? cb : () => {};
    const { duelId, result } = payload ?? {};
    if (!duelId || result === undefined) {
      respond({ ok: false, error: 'MISSING_FIELDS' });
      return;
    }
    respond(await duelService.submit({ duelId, userId, result }));
  });

  socket.once('disconnect', async () => {
    const duel = duelService.getDuelForUser(userId);
    const shouldClearDuelLock = duel?.status === 'in_game';
    duelService.handleDisconnect(userId);
    if (duel && shouldClearDuelLock) {
      await setDuelLockState(
        io,
        duel.sessionId,
        [duel.challengerId, duel.targetId],
        false,
      );
    }
  });
};
