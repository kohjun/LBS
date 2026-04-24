'use strict';

const DEFAULT_MIN_TOTAL_PLAYERS = 9;
const MIN_PLAYERS_PER_TEAM = 2;

function getConfiguredTeams(config = {}) {
  const teams = Array.isArray(config.teams) ? config.teams : [];
  return teams.filter((team) => typeof team?.teamId === 'string' && team.teamId);
}

export function validateFantasyWarsStart(members = [], config = {}) {
  const teams = getConfiguredTeams(config);
  const teamIds = teams.map((team) => team.teamId);
  const teamCounts = Object.fromEntries(teamIds.map((teamId) => [teamId, 0]));
  let unassignedCount = 0;

  members.forEach((member) => {
    const teamId = member?.team_id;
    if (!teamId || !(teamId in teamCounts)) {
      unassignedCount += 1;
      return;
    }

    teamCounts[teamId] += 1;
  });

  const requiredTotalPlayers = Math.max(
    DEFAULT_MIN_TOTAL_PLAYERS,
    Math.max(teams.length, 1) * 3,
  );
  const undersizedTeams = teams
    .filter((team) => (teamCounts[team.teamId] ?? 0) < MIN_PLAYERS_PER_TEAM)
    .map((team) => ({
      teamId: team.teamId,
      displayName: team.displayName ?? team.teamId,
      memberCount: teamCounts[team.teamId] ?? 0,
      requiredCount: MIN_PLAYERS_PER_TEAM,
    }));

  if (members.length < requiredTotalPlayers) {
    const error = new Error('FANTASY_WARS_NOT_ENOUGH_PLAYERS');
    error.details = {
      required: requiredTotalPlayers,
      current: members.length,
      perTeamTarget: 3,
      teamCounts,
    };
    throw error;
  }

  if (unassignedCount > 0) {
    const error = new Error('FANTASY_WARS_TEAM_ASSIGNMENT_REQUIRED');
    error.details = {
      unassignedCount,
      teamCounts,
    };
    throw error;
  }

  if (undersizedTeams.length > 0) {
    const error = new Error('FANTASY_WARS_TEAM_SIZE_TOO_SMALL');
    error.details = {
      minimumPlayersPerTeam: MIN_PLAYERS_PER_TEAM,
      undersizedTeams,
      teamCounts,
    };
    throw error;
  }

  return {
    requiredTotalPlayers,
    minimumPlayersPerTeam: MIN_PLAYERS_PER_TEAM,
    teamCounts,
  };
}
