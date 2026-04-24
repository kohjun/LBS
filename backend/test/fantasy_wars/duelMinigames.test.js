import test from 'node:test';
import assert from 'node:assert/strict';

import {
  generateMinigameParams,
  buildPublicMinigameParams,
  judgeMinigame,
} from '../../src/game/duel/FantasyWarsMinigames.js';

function scoreHand(cards) {
  let total = cards.reduce((sum, card) => sum + card, 0);
  let aces = cards.filter((card) => card === 11).length;
  while (total > 21 && aces > 0) {
    total -= 10;
    aces -= 1;
  }
  return total > 21 ? 0 : total;
}

function findBlackjackWinner(params, participants) {
  const bestByUser = {};

  participants.forEach((userId) => {
    const baseHand = params.handsByUser[userId];
    const drawPile = params.drawPilesByUser[userId];
    let bestScore = -1;
    let bestHitCount = 0;

    for (let hitCount = 0; hitCount <= drawPile.length; hitCount += 1) {
      const score = scoreHand([...baseHand, ...drawPile.slice(0, hitCount)]);
      if (score > bestScore) {
        bestScore = score;
        bestHitCount = hitCount;
      }
    }

    bestByUser[userId] = { bestScore, bestHitCount };
  });

  const [left, right] = participants;
  if (bestByUser[left].bestScore === bestByUser[right].bestScore) {
    return null;
  }

  return bestByUser[left].bestScore > bestByUser[right].bestScore
    ? { winner: left, loser: right, picks: bestByUser }
    : { winner: right, loser: left, picks: bestByUser };
}

test('precision minigame uses shared target list for judging', () => {
  const params = generateMinigameParams('precision', 'seed-precision');
  assert.equal(params.shots, 3);
  assert.equal(params.targets.length, 3);

  const submissions = {
    alpha: {
      hits: params.targets.map((target) => ({ x: target.x, y: target.y })),
    },
    beta: {
      hits: params.targets.map((target) => ({
        x: Math.min(1, target.x + 0.08),
        y: Math.min(1, target.y + 0.08),
      })),
    },
  };

  const verdict = judgeMinigame('precision', 'seed-precision', submissions, params);
  assert.equal(verdict.winner, 'alpha');
  assert.equal(verdict.reason, 'better_precision');
});

test('speed blackjack exposes only the participant hand and draw pile', () => {
  const participants = ['user-1', 'user-2'];
  const params = generateMinigameParams('speed_blackjack', 'seed-blackjack', participants);

  const publicParams = buildPublicMinigameParams('speed_blackjack', params, 'user-1');
  assert.deepEqual(publicParams.hand, params.handsByUser['user-1']);
  assert.deepEqual(publicParams.drawPile, params.drawPilesByUser['user-1']);
  assert.equal(publicParams.hand.length, 2);
  assert.ok(publicParams.drawPile.length > 0);
});

test('speed blackjack verdict is computed from server-side hands and hit counts', () => {
  const participants = ['user-1', 'user-2'];
  const params = generateMinigameParams('speed_blackjack', 'seed-blackjack-score', participants);
  const expected = findBlackjackWinner(params, participants);

  assert.ok(expected, 'expected a non-draw blackjack seed for this test');

  const submissions = {
    'user-1': { hitCount: expected.picks['user-1'].bestHitCount },
    'user-2': { hitCount: expected.picks['user-2'].bestHitCount },
  };

  const verdict = judgeMinigame(
    'speed_blackjack',
    'seed-blackjack-score',
    submissions,
    params,
  );

  assert.equal(verdict.winner, expected.winner);
  assert.equal(verdict.loser, expected.loser);
  assert.equal(verdict.reason, 'higher_hand');
});
