import { redisClient } from '../config/redis.js';
import * as sessionService from '../services/sessionService.js';
import * as MissionSystem from './MissionSystem.js';

const GAME_TTL_SECONDS = 86400;

const GAME_EVENTS = {
  started: 'game:started',
  roleAssigned: 'game:role_assigned',
};

const normalizeAliveMembers = (members) =>
  members.filter((member) => member?.user_id);

const getMinPlayers = () => 2;

export const startGameForSession = async ({
  io,
  sessionId,
  requesterUserId,
}) => {
  const session = await sessionService.getSession(sessionId);
  if (!session) {
    const error = new Error('SESSION_NOT_FOUND');
    throw error;
  }

  if (session.host_user_id !== requesterUserId) {
    const error = new Error('NOT_HOST');
    throw error;
  }

  const members = await sessionService.getSessionMembers(sessionId);
  const aliveMembers = normalizeAliveMembers(members);
  const minPlayers = getMinPlayers();

  if (aliveMembers.length < minPlayers) {
    const error = new Error('NOT_ENOUGH_PLAYERS');
    error.details = {
      required: minPlayers,
      current: aliveMembers.length,
    };
    throw error;
  }

  const impostorCount = Math.max(
    1,
    Math.min(
      Number.isInteger(session.impostor_count) ? session.impostor_count : 1,
      Math.max(1, aliveMembers.length - 1),
    ),
  );
  const shuffledMembers = [...aliveMembers].sort(() => Math.random() - 0.5);
  const impostors = new Set(
    shuffledMembers.slice(0, impostorCount).map((member) => member.user_id),
  );
  const startedAt = Date.now();
  const gameState = {
    status: 'in_progress',
    startedAt,
    impostors: [...impostors],
    alivePlayerIds: aliveMembers.map((member) => member.user_id),
    killLog: [],
    meetingCount: 0,
  };

  await Promise.all([
    redisClient.set(`game:${sessionId}`, JSON.stringify(gameState), {
      EX: GAME_TTL_SECONDS,
    }),
    redisClient.set(`game:${sessionId}:status`, gameState.status, {
      EX: GAME_TTL_SECONDS,
    }),
    redisClient.set(`game:${sessionId}:started`, '1', {
      EX: GAME_TTL_SECONDS,
    }),
  ]);

  const startedPayload = {
    sessionId,
    playerCount: aliveMembers.length,
    impostorCount,
    startedAt: new Date(startedAt).toISOString(),
    activeModules: Array.isArray(session.active_modules)
      ? session.active_modules
      : [],
  };

  io.to(`session:${sessionId}`).emit(GAME_EVENTS.started, startedPayload);

  for (const member of aliveMembers) {
    const isImpostor = impostors.has(member.user_id);
    io.to(`user:${member.user_id}`).emit(GAME_EVENTS.roleAssigned, {
      role: isImpostor ? 'impostor' : 'crew',
      team: isImpostor ? 'impostor' : 'crew',
      impostors: isImpostor ? [...impostors] : [],
    });
  }

  await MissionSystem.assignMissions(session, aliveMembers);

  return {
    session,
    aliveMembers,
    gameState,
    startedPayload,
  };
};
