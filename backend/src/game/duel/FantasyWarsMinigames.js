'use strict';

import { createHash } from 'crypto';

export const MINIGAME_TYPES = [
  'reaction_time',
  'rapid_tap',
  'precision',
  'russian_roulette',
  'speed_blackjack',
];

const PRECISION_SHOTS = 3;
const BLACKJACK_DRAW_LIMIT = 8;
const BLACKJACK_TARGET_SCORE = 21;
const BLACKJACK_TIMEOUT_SEC = 15;

function sr(seed, idx) {
  const hex = createHash('sha256').update(`${seed}:${idx}`).digest('hex');
  return parseInt(hex.slice(0, 8), 16) / 0xffffffff;
}

function clamp01(value, fallback = 1) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) {
    return fallback;
  }

  return Math.min(1, Math.max(0, numeric));
}

function clampInt(value, min, max, fallback = min) {
  const numeric = Number.parseInt(value, 10);
  if (!Number.isFinite(numeric)) {
    return fallback;
  }

  return Math.min(max, Math.max(min, numeric));
}

function round4(value) {
  return Math.round(value * 10_000) / 10_000;
}

function buildPrecisionTargets(seed, shots = PRECISION_SHOTS) {
  return Array.from({ length: shots }, (_, index) => ({
    x: round4(0.15 + sr(seed, 1 + index * 2) * 0.7),
    y: round4(0.18 + sr(seed, 2 + index * 2) * 0.64),
  }));
}

function buildBlackjackDeck(seed) {
  const deck = [];
  for (let value = 1; value <= 13; value += 1) {
    const cardValue = value === 1 ? 11 : Math.min(value, 10);
    for (let suit = 0; suit < 4; suit += 1) {
      deck.push(cardValue);
    }
  }

  for (let index = deck.length - 1; index > 0; index -= 1) {
    const swapIndex = Math.floor(sr(seed, index + 100) * (index + 1));
    [deck[index], deck[swapIndex]] = [deck[swapIndex], deck[index]];
  }

  return deck;
}

function buildBlackjackState(seed, participants) {
  const deck = buildBlackjackDeck(seed);
  const handsByUser = {};
  const drawPilesByUser = {};
  let cursor = 0;

  participants.forEach((userId) => {
    handsByUser[userId] = [deck[cursor], deck[cursor + 1]];
    cursor += 2;
  });

  participants.forEach((userId) => {
    drawPilesByUser[userId] = deck.slice(cursor, cursor + BLACKJACK_DRAW_LIMIT);
    cursor += BLACKJACK_DRAW_LIMIT;
  });

  return { handsByUser, drawPilesByUser };
}

function scoreBlackjackHand(cards) {
  let total = cards.reduce((sum, card) => sum + card, 0);
  let aces = cards.filter((card) => card === 11).length;

  while (total > BLACKJACK_TARGET_SCORE && aces > 0) {
    total -= 10;
    aces -= 1;
  }

  return total > BLACKJACK_TARGET_SCORE ? 0 : total;
}

function scorePrecisionSubmission(submission, targets) {
  const hits = Array.isArray(submission?.hits) ? submission.hits : [];
  let totalDistance = 0;

  for (let index = 0; index < targets.length; index += 1) {
    const target = targets[index];
    const hit = hits[index];

    if (!target || !hit) {
      totalDistance += 2;
      continue;
    }

    totalDistance += Math.hypot(
      clamp01(hit.x) - target.x,
      clamp01(hit.y) - target.y,
    );
  }

  return totalDistance;
}

function scoreBlackjackSubmission(userId, submission, params) {
  const baseHand = Array.isArray(params?.handsByUser?.[userId])
    ? params.handsByUser[userId]
    : [];
  const drawPile = Array.isArray(params?.drawPilesByUser?.[userId])
    ? params.drawPilesByUser[userId]
    : [];
  const hitCount = clampInt(submission?.hitCount, 0, drawPile.length, 0);
  const cards = [...baseHand, ...drawPile.slice(0, hitCount)];
  return scoreBlackjackHand(cards);
}

export function pickMinigame(seed) {
  const idx = Math.floor(sr(seed, 0) * MINIGAME_TYPES.length);
  return MINIGAME_TYPES[idx];
}

export function generateMinigameParams(type, seed, participants = []) {
  switch (type) {
    case 'reaction_time':
      return {
        signalDelayMs: Math.floor(500 + sr(seed, 1) * 1500),
      };

    case 'rapid_tap':
      return {
        durationSec: 5,
      };

    case 'precision':
      return {
        shots: PRECISION_SHOTS,
        targets: buildPrecisionTargets(seed),
      };

    case 'russian_roulette':
      return {
        chamberCount: 6,
      };

    case 'speed_blackjack': {
      const { handsByUser, drawPilesByUser } = buildBlackjackState(seed, participants);
      return {
        targetScore: BLACKJACK_TARGET_SCORE,
        timeoutSec: BLACKJACK_TIMEOUT_SEC,
        handsByUser,
        drawPilesByUser,
      };
    }

    default:
      return {};
  }
}

export function buildPublicMinigameParams(type, params, participantId) {
  switch (type) {
    case 'speed_blackjack':
      return {
        targetScore: params?.targetScore ?? BLACKJACK_TARGET_SCORE,
        timeoutSec: params?.timeoutSec ?? BLACKJACK_TIMEOUT_SEC,
        hand: Array.isArray(params?.handsByUser?.[participantId])
          ? params.handsByUser[participantId]
          : [],
        drawPile: Array.isArray(params?.drawPilesByUser?.[participantId])
          ? params.drawPilesByUser[participantId]
          : [],
      };

    case 'precision':
      return {
        shots: params?.shots ?? PRECISION_SHOTS,
        targets: Array.isArray(params?.targets) ? params.targets : [],
      };

    case 'rapid_tap':
      return {
        durationSec: params?.durationSec ?? 5,
      };

    case 'reaction_time':
      return {
        signalDelayMs: params?.signalDelayMs ?? 1000,
      };

    case 'russian_roulette':
      return {
        chamberCount: params?.chamberCount ?? 6,
      };

    default:
      return params ?? {};
  }
}

export function judgeMinigame(type, seed, submissions, params) {
  const ids = Object.keys(submissions);
  if (ids.length < 2) {
    return { winner: null, loser: null, reason: 'insufficient_players' };
  }

  const [p1, p2] = ids;
  const s1 = submissions[p1] ?? {};
  const s2 = submissions[p2] ?? {};

  switch (type) {
    case 'reaction_time': {
      const r1 = Number.isFinite(s1.reactionMs) && s1.reactionMs >= 0 ? s1.reactionMs : Infinity;
      const r2 = Number.isFinite(s2.reactionMs) && s2.reactionMs >= 0 ? s2.reactionMs : Infinity;
      if (r1 === r2) {
        return { winner: null, loser: null, reason: 'draw' };
      }

      return r1 < r2
        ? { winner: p1, loser: p2, reason: 'faster_reaction' }
        : { winner: p2, loser: p1, reason: 'faster_reaction' };
    }

    case 'rapid_tap': {
      const rate = (submission) => (
        submission?.tapCount != null && submission?.durationMs > 0
          ? submission.tapCount / submission.durationMs
          : 0
      );
      const r1 = rate(s1);
      const r2 = rate(s2);
      if (Math.abs(r1 - r2) < 1e-6) {
        return { winner: null, loser: null, reason: 'draw' };
      }

      return r1 > r2
        ? { winner: p1, loser: p2, reason: 'faster_tap' }
        : { winner: p2, loser: p1, reason: 'faster_tap' };
    }

    case 'precision': {
      const targets = Array.isArray(params?.targets) ? params.targets : buildPrecisionTargets(seed);
      const d1 = scorePrecisionSubmission(s1, targets);
      const d2 = scorePrecisionSubmission(s2, targets);
      if (Math.abs(d1 - d2) < 1e-6) {
        return { winner: null, loser: null, reason: 'draw' };
      }

      return d1 < d2
        ? { winner: p1, loser: p2, reason: 'better_precision' }
        : { winner: p2, loser: p1, reason: 'better_precision' };
    }

    case 'russian_roulette': {
      const bullet = Math.floor(sr(seed, 3) * 6) + 1;
      const hit1 = s1.chamber === bullet;
      const hit2 = s2.chamber === bullet;
      if (hit1 && !hit2) {
        return { winner: p2, loser: p1, reason: 'bullet_hit' };
      }
      if (hit2 && !hit1) {
        return { winner: p1, loser: p2, reason: 'bullet_hit' };
      }
      if (!hit1 && !hit2) {
        return { winner: null, loser: null, reason: 'both_survived' };
      }

      return { winner: null, loser: null, reason: 'simultaneous_hit' };
    }

    case 'speed_blackjack': {
      const sc1 = scoreBlackjackSubmission(p1, s1, params);
      const sc2 = scoreBlackjackSubmission(p2, s2, params);
      if (sc1 === sc2) {
        return { winner: null, loser: null, reason: 'draw' };
      }

      return sc1 > sc2
        ? { winner: p1, loser: p2, reason: 'higher_hand' }
        : { winner: p2, loser: p1, reason: 'higher_hand' };
    }

    default:
      return { winner: null, loser: null, reason: 'unknown_minigame' };
  }
}
