'use strict';

import crypto from 'crypto';
import {
  pickMinigame,
  generateMinigameParams,
  buildPublicMinigameParams,
  judgeMinigame,
} from './FantasyWarsMinigames.js';

const CHALLENGE_TIMEOUT_MS = 15_000;
const GAME_TIMEOUT_MS = 30_000;

const activeDuels = new Map();
const playerDuelMap = new Map();

class DuelService {
  challenge({ challengerId, targetId, sessionId, transport, onResolve, onInvalidate }) {
    if (!challengerId || !targetId || !sessionId) {
      return { ok: false, error: 'MISSING_FIELDS' };
    }
    if (challengerId === targetId) {
      return { ok: false, error: 'CANNOT_CHALLENGE_SELF' };
    }
    if (playerDuelMap.has(challengerId)) {
      return { ok: false, error: 'CHALLENGER_IN_DUEL' };
    }
    if (playerDuelMap.has(targetId)) {
      return { ok: false, error: 'TARGET_IN_DUEL' };
    }

    const duelId = crypto.randomUUID();
    const seed = crypto.randomBytes(16).toString('hex');
    const record = {
      duelId,
      sessionId,
      challengerId,
      targetId,
      seed,
      status: 'challenged',
      minigameType: null,
      params: null,
      submissions: {},
      startedAt: null,
      resolvedAt: null,
      onResolve,
      onInvalidate,
      _transport: transport,
      _challengeTimer: null,
      _gameTimer: null,
    };

    activeDuels.set(duelId, record);
    playerDuelMap.set(challengerId, duelId);
    playerDuelMap.set(targetId, duelId);

    record._challengeTimer = setTimeout(
      () => this._invalidate(duelId, 'challenge_timeout'),
      CHALLENGE_TIMEOUT_MS,
    );

    transport.sendToUser(targetId, 'fw:duel:challenged', {
      duelId,
      challengerId,
      sessionId,
      expiresInMs: CHALLENGE_TIMEOUT_MS,
    });
    transport.sendToUser(challengerId, 'fw:duel:challenged', {
      duelId,
      targetId,
      sessionId,
      self: true,
    });

    return { ok: true, duelId };
  }

  accept({ duelId, userId }) {
    const record = activeDuels.get(duelId);
    if (!record || record.status !== 'challenged') {
      return { ok: false, error: 'DUEL_NOT_PENDING' };
    }
    if (record.targetId !== userId) {
      return { ok: false, error: 'NOT_TARGET' };
    }

    clearTimeout(record._challengeTimer);

    const minigameType = pickMinigame(record.seed);
    const params = generateMinigameParams(
      minigameType,
      record.seed,
      [record.challengerId, record.targetId],
    );
    record.status = 'in_game';
    record.startedAt = Date.now();
    record.minigameType = minigameType;
    record.params = params;

    record._gameTimer = setTimeout(
      () => void this._resolveTimeout(duelId),
      GAME_TIMEOUT_MS,
    );

    const startPayload = {
      duelId,
      minigameType,
      gameTimeoutMs: GAME_TIMEOUT_MS,
      startedAt: record.startedAt,
    };

    record._transport.sendToUser(record.challengerId, 'fw:duel:started', {
      ...startPayload,
      params: buildPublicMinigameParams(minigameType, params, record.challengerId),
    });
    record._transport.sendToUser(record.targetId, 'fw:duel:started', {
      ...startPayload,
      params: buildPublicMinigameParams(minigameType, params, record.targetId),
    });
    record._transport.sendToSession(record.sessionId, 'fw:duel:accepted', {
      duelId,
      challengerId: record.challengerId,
      targetId: record.targetId,
      minigameType,
    });

    return {
      ok: true,
      duelId,
      startedAt: record.startedAt,
      gameTimeoutMs: GAME_TIMEOUT_MS,
      challengerId: record.challengerId,
      targetId: record.targetId,
    };
  }

  reject({ duelId, userId }) {
    const record = activeDuels.get(duelId);
    if (!record || record.status !== 'challenged') {
      return { ok: false, error: 'DUEL_NOT_PENDING' };
    }
    if (record.targetId !== userId) {
      return { ok: false, error: 'NOT_TARGET' };
    }

    clearTimeout(record._challengeTimer);
    record._transport.sendToUser(record.challengerId, 'fw:duel:rejected', { duelId });
    record._transport.sendToUser(record.targetId, 'fw:duel:rejected', { duelId });
    this._close(record, 'rejected');
    return { ok: true };
  }

  cancel({ duelId, userId }) {
    const record = activeDuels.get(duelId);
    if (!record || record.status !== 'challenged') {
      return { ok: false, error: 'DUEL_NOT_PENDING' };
    }
    if (record.challengerId !== userId) {
      return { ok: false, error: 'NOT_CHALLENGER' };
    }

    clearTimeout(record._challengeTimer);
    record._transport.sendToUser(record.targetId, 'fw:duel:cancelled', { duelId });
    record._transport.sendToUser(record.challengerId, 'fw:duel:cancelled', { duelId });
    this._close(record, 'cancelled');
    return { ok: true };
  }

  async submit({ duelId, userId, result }) {
    const record = activeDuels.get(duelId);
    if (!record || record.status !== 'in_game') {
      return { ok: false, error: 'DUEL_NOT_ACTIVE' };
    }
    if (userId !== record.challengerId && userId !== record.targetId) {
      return { ok: false, error: 'NOT_PARTICIPANT' };
    }
    if (record.submissions[userId]) {
      return { ok: false, error: 'ALREADY_SUBMITTED' };
    }

    record.submissions[userId] = { result, submittedAt: Date.now() };
    if (Object.keys(record.submissions).length >= 2) {
      await this._resolve(duelId);
    }
    return { ok: true };
  }

  handleDisconnect(userId) {
    const duelId = playerDuelMap.get(userId);
    if (!duelId) {
      return;
    }

    const record = activeDuels.get(duelId);
    if (!record) {
      return;
    }

    const terminalStatuses = ['resolved', 'cancelled', 'rejected', 'invalidated'];
    if (terminalStatuses.includes(record.status)) {
      return;
    }

    this._invalidate(duelId, 'disconnect');
  }

  getDuelForUser(userId) {
    const duelId = playerDuelMap.get(userId);
    return duelId ? (activeDuels.get(duelId) ?? null) : null;
  }

  getDuel(duelId) {
    return activeDuels.get(duelId) ?? null;
  }

  isInDuel(userId) {
    return playerDuelMap.has(userId);
  }

  invalidate(duelId, reason = 'invalid_state') {
    this._invalidate(duelId, reason);
  }

  async _resolve(duelId) {
    const record = activeDuels.get(duelId);
    if (!record || record.status !== 'in_game') {
      return;
    }

    clearTimeout(record._gameTimer);

    const subResults = Object.fromEntries(
      Object.entries(record.submissions).map(([userId, submission]) => [userId, submission.result]),
    );

    let verdict = judgeMinigame(
      record.minigameType,
      record.seed,
      subResults,
      record.params,
    );
    verdict = await this._finalizeVerdict(record, verdict, record.resolvedAt ?? Date.now());

    const resultPayload = {
      duelId,
      minigameType: record.minigameType,
      verdict,
      resolvedAt: record.resolvedAt,
    };

    record._transport.sendToUser(record.challengerId, 'fw:duel:result', resultPayload);
    record._transport.sendToUser(record.targetId, 'fw:duel:result', resultPayload);
    record._transport.sendToSession(record.sessionId, 'fw:duel:result', resultPayload);

    this._close(record, 'resolved');
  }

  async _resolveTimeout(duelId) {
    const record = activeDuels.get(duelId);
    if (!record || record.status !== 'in_game') {
      return;
    }

    const submitted = new Set(Object.keys(record.submissions));
    const participants = [record.challengerId, record.targetId];
    const didNotSubmit = participants.filter((id) => !submitted.has(id));
    const didSubmit = participants.filter((id) => submitted.has(id));

    let verdict;
    if (didNotSubmit.length === 1) {
      verdict = {
        winner: didSubmit[0],
        loser: didNotSubmit[0],
        reason: 'opponent_timeout',
      };
    } else {
      verdict = { winner: null, loser: null, reason: 'both_timed_out' };
    }

    verdict = await this._finalizeVerdict(record, verdict, Date.now());

    const resultPayload = {
      duelId,
      minigameType: record.minigameType,
      verdict,
      resolvedAt: record.resolvedAt,
      timedOut: true,
    };

    record._transport.sendToUser(record.challengerId, 'fw:duel:result', resultPayload);
    record._transport.sendToUser(record.targetId, 'fw:duel:result', resultPayload);
    record._transport.sendToSession(record.sessionId, 'fw:duel:result', resultPayload);

    this._close(record, 'resolved');
  }

  async _finalizeVerdict(record, verdict, resolvedAt) {
    record.resolvedAt = resolvedAt;

    if (!record.onResolve) {
      return verdict;
    }

    const resolution = await record.onResolve({
      duelId: record.duelId,
      winnerId: verdict.winner,
      loserId: verdict.loser,
      reason: verdict.reason,
      minigameType: record.minigameType,
      sessionId: record.sessionId,
    }).catch((err) => {
      console.error('[Duel] onResolve error:', err);
      return null;
    });

    let nextVerdict = verdict;
    if (resolution?.verdict) {
      nextVerdict = { ...nextVerdict, ...resolution.verdict };
    }
    if (resolution?.effects) {
      nextVerdict = { ...nextVerdict, effects: resolution.effects };
    }
    return nextVerdict;
  }

  _invalidate(duelId, reason) {
    const record = activeDuels.get(duelId);
    if (!record) {
      return;
    }

    clearTimeout(record._challengeTimer);
    clearTimeout(record._gameTimer);

    record._transport.sendToUser(record.challengerId, 'fw:duel:invalidated', { duelId, reason });
    record._transport.sendToUser(record.targetId, 'fw:duel:invalidated', { duelId, reason });
    if (record.onInvalidate) {
      Promise.resolve(
        record.onInvalidate({
          duelId,
          sessionId: record.sessionId,
          challengerId: record.challengerId,
          targetId: record.targetId,
          reason,
        }),
      ).catch((err) => {
        console.error('[Duel] onInvalidate error:', err);
      });
    }

    this._close(record, 'invalidated');
    console.log(`[Duel] invalidated duelId=${duelId} reason=${reason}`);
  }

  _close(record, finalStatus) {
    record.status = finalStatus;
    playerDuelMap.delete(record.challengerId);
    playerDuelMap.delete(record.targetId);
    activeDuels.delete(record.duelId);
  }
}

export const duelService = new DuelService();
