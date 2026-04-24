import test from 'node:test';
import assert from 'node:assert/strict';

import { validateFantasyWarsStart } from '../../src/game/plugins/fantasy_wars_artifact/startValidation.js';

function makeConfig() {
  return {
    teamCount: 3,
    teams: [
      { teamId: 'guild_alpha', displayName: '붉은 길드' },
      { teamId: 'guild_beta', displayName: '푸른 길드' },
      { teamId: 'guild_gamma', displayName: '초록 길드' },
    ],
  };
}

function makeMembers(teamAssignments) {
  return teamAssignments.map((teamId, index) => ({
    user_id: `user-${index + 1}`,
    team_id: teamId,
  }));
}

test('validateFantasyWarsStart accepts a 3-3-3 lobby', () => {
  const result = validateFantasyWarsStart(
    makeMembers([
      'guild_alpha', 'guild_alpha', 'guild_alpha',
      'guild_beta', 'guild_beta', 'guild_beta',
      'guild_gamma', 'guild_gamma', 'guild_gamma',
    ]),
    makeConfig(),
  );

  assert.equal(result.requiredTotalPlayers, 9);
  assert.equal(result.minimumPlayersPerTeam, 2);
  assert.deepEqual(result.teamCounts, {
    guild_alpha: 3,
    guild_beta: 3,
    guild_gamma: 3,
  });
});

test('validateFantasyWarsStart rejects lobbies below the minimum total player count', () => {
  assert.throws(
    () => validateFantasyWarsStart(
      makeMembers([
        'guild_alpha', 'guild_alpha',
        'guild_beta', 'guild_beta',
        'guild_gamma', 'guild_gamma',
      ]),
      makeConfig(),
    ),
    (error) => {
      assert.equal(error.message, 'FANTASY_WARS_NOT_ENOUGH_PLAYERS');
      assert.equal(error.details.required, 9);
      assert.equal(error.details.current, 6);
      return true;
    },
  );
});

test('validateFantasyWarsStart rejects unassigned players before game start', () => {
  assert.throws(
    () => validateFantasyWarsStart(
      makeMembers([
        'guild_alpha', 'guild_alpha', 'guild_alpha',
        'guild_beta', 'guild_beta', 'guild_beta',
        'guild_gamma', 'guild_gamma', null,
      ]),
      makeConfig(),
    ),
    (error) => {
      assert.equal(error.message, 'FANTASY_WARS_TEAM_ASSIGNMENT_REQUIRED');
      assert.equal(error.details.unassignedCount, 1);
      return true;
    },
  );
});

test('validateFantasyWarsStart rejects teams that cannot support capture play', () => {
  assert.throws(
    () => validateFantasyWarsStart(
      makeMembers([
        'guild_alpha', 'guild_alpha', 'guild_alpha', 'guild_alpha', 'guild_alpha',
        'guild_beta', 'guild_beta', 'guild_beta',
        'guild_gamma',
      ]),
      makeConfig(),
    ),
    (error) => {
      assert.equal(error.message, 'FANTASY_WARS_TEAM_SIZE_TOO_SMALL');
      assert.equal(error.details.minimumPlayersPerTeam, 2);
      assert.deepEqual(error.details.undersizedTeams, [
        {
          teamId: 'guild_gamma',
          displayName: '초록 길드',
          memberCount: 1,
          requiredCount: 2,
        },
      ]);
      return true;
    },
  );
});
