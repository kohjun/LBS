import { redisClient } from '../config/redis.js';
import * as sessionService from '../services/sessionService.js';
import * as MissionSystem from './MissionSystem.js';
import * as AIDirector from '../ai/AIDirector.js';
import { getMediaServer } from '../media/MediaServer.js';

const GAME_TTL_SECONDS = 86400;

const GAME_EVENTS = {
  started: 'game:started',
  roleAssigned: 'game:role_assigned',
  aiMessage: 'game:ai_message',
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

  const mediaRoom = getMediaServer()?.getRoom(sessionId);
  if (mediaRoom) {
    mediaRoom.setAlivePeers(aliveMembers.map((member) => member.user_id));
    mediaRoom.muteAll();
  }

  io.to(`session:${sessionId}`).emit(GAME_EVENTS.started, startedPayload);

  try {
    const roomLike = {
      players: new Map(
        aliveMembers.map((member) => [
          member.user_id,
          {
            userId: member.user_id,
            nickname: member.nickname ?? member.user_id,
            team: impostors.has(member.user_id) ? 'impostor' : 'crew',
          },
        ]),
      ),
      impostors: [...impostors],
    };
    const msg = await AIDirector.onGameStart(roomLike);
    if (msg) {
      io.to(`session:${sessionId}`).emit(GAME_EVENTS.aiMessage, {
        type: 'announcement',
        message: msg,
      });
    }
  } catch (error) {
    console.error('[AI] game start announcement failed:', error.message);
  }

  for (const member of aliveMembers) {
    const isImpostor = impostors.has(member.user_id);
    io.to(`user:${member.user_id}`).emit(GAME_EVENTS.roleAssigned, {
      role: isImpostor ? 'impostor' : 'crew',
      team: isImpostor ? 'impostor' : 'crew',
      impostors: isImpostor ? [...impostors] : [],
    });
  }

  await MissionSystem.assignMissions(session, aliveMembers);

  // 각 플레이어에게 자신의 미션 목록 전송
  for (const member of aliveMembers) {
    const missions = await MissionSystem.getMissions(sessionId, member.user_id);
    if (missions && missions.length > 0) {
      io.to(`user:${member.user_id}`).emit('game:missions_assigned', { missions });
    }
  }

  return {
    session,
    aliveMembers,
    gameState,
    startedPayload,
  };
};
