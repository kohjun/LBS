// src/routes/sessions.js
import { z } from 'zod';
import { authenticate } from '../middleware/auth.js';
import * as sessionService from '../services/sessionService.js';
import * as locationService from '../services/locationService.js';
import { getIo, EVENTS } from '../websocket/index.js';
import { startGameForSession } from '../game/startGameService.js';
import * as AIDirector from '../ai/AIDirector.js';
import { redisClient } from '../config/redis.js';
import { keys } from '../websocket/socketRuntime.js';
import * as MissionSystem from '../game/MissionSystem.js';

const createSessionSchema = z.object({
  name: z.string().max(100).optional(),
  activeModules: z.array(z.string()).max(10).optional(),
  durationHours: z.number().min(1).max(72).optional(),
  maxMembers: z.number().min(2).max(50).optional(),
  gameType: z.string().optional(),
  gameConfig: z.record(z.unknown()).optional(),
  gameVersion: z.string().max(20).optional(),
  impostorCount: z.number().min(1).max(3).optional(),
  killCooldown: z.number().min(10).max(60).optional(),
  discussionTime: z.number().min(30).max(180).optional(),
  voteTime: z.number().min(15).max(60).optional(),
  missionPerCrew: z.number().min(1).max(5).optional(),
  settings: z.object({
    killCooldown:      z.number().min(10).max(60).optional(),
    emergencyCooldown: z.number().min(30).max(180).optional(),
    voteTime:          z.number().min(15).max(60).optional(),
    missionPerCrew:    z.number().min(1).max(5).optional(),
  }).optional(),
});

const geoPointSchema = z.object({
  lat: z.number().finite().min(-90).max(90),
  lng: z.number().finite().min(-180).max(180),
});

const polygonSchema = z.array(geoPointSchema).min(3);

const fantasyWarsLayoutSchema = z.object({
  playableArea: polygonSchema,
  controlPoints: z.array(geoPointSchema).min(1),
  spawnZones: z.array(z.object({
    teamId: z.string().min(1),
    polygonPoints: polygonSchema,
  })).min(1),
});

const fantasyWarsDuelConfigSchema = z.object({
  allowGpsFallbackWithoutBle: z.boolean().optional(),
  bleEvidenceFreshnessMs: z.number().int().min(2000).max(60000).optional(),
}).refine(
  (value) => Object.keys(value).length > 0,
  { message: 'EMPTY_DUEL_CONFIG' },
);

// [Task 5] settings 중첩 객체를 최상위 필드로 병합 (기존 최상위 값이 우선)
const normalizeCreateSessionBody = (body = {}) => {
  const { settings, ...rest } = body;
  return {
    ...rest,
    activeModules:  rest.activeModules ?? rest.active_modules,
    killCooldown:   rest.killCooldown   ?? settings?.killCooldown,
    discussionTime: rest.discussionTime ?? settings?.emergencyCooldown,
    voteTime:       rest.voteTime       ?? settings?.voteTime,
    missionPerCrew: rest.missionPerCrew ?? settings?.missionPerCrew,
    gameConfig:     rest.gameConfig     ?? {},
    gameVersion:    rest.gameVersion    ?? '1.0',
  };
};

export default async function sessionRoutes(fastify) {
  const cleanupAiHistory = async ({ roomId, userId }) => {
    try {
      if (userId) {
        await AIDirector.clearHistory(roomId, userId);
        return;
      }

      await AIDirector.cleanupRoom(roomId);
    } catch (error) {
      fastify.log.warn(
        { error, roomId, userId },
        '[AI] Failed to clean session history',
      );
    }
  };

  const cleanupGameState = async (sessionId) => {
    try {
      await Promise.all([
        redisClient.del(keys.state(sessionId)),
        redisClient.del(keys.started(sessionId)),
        MissionSystem.clearSession(sessionId),
      ]);
    } catch (error) {
      fastify.log.warn({ error, sessionId }, '[Game] Failed to clean game state from Redis');
    }
  };

  fastify.removeContentTypeParser('application/json');
  fastify.addContentTypeParser(
    'application/json',
    { parseAs: 'string' },
    (req, body, done) => {
      if (!body) {
        done(null, {});
        return;
      }

      try {
        done(null, JSON.parse(body));
      } catch (err) {
        err.statusCode = 400;
        done(err);
      }
    },
  );

  fastify.addHook('preHandler', authenticate);

  fastify.post('/', async (request, reply) => {
    const parsed = createSessionSchema.safeParse(
      normalizeCreateSessionBody(request.body || {}),
    );
    if (!parsed.success) {
      return reply.code(400).send({ error: 'VALIDATION_ERROR' });
    }

    const session = await sessionService.createSession(request.user.id, parsed.data);
    return reply.code(201).send({ session });
  });

  // ── 플레이 가능 영역(폴리곤) 설정 (호스트 전용) ──────────────────────────────
  fastify.patch('/:sessionId/playable-area', async (request, reply) => {
    const { sessionId } = request.params;
    const { polygonPoints } = request.body || {};

    if (!Array.isArray(polygonPoints) || polygonPoints.length < 3) {
      return reply.code(400).send({ error: 'INVALID_POLYGON' });
    }

    // 각 포인트가 {lat, lng} 형태인지 검증
    const isValidPoints = polygonPoints.every(
      (p) =>
        typeof p === 'object' &&
        typeof p.lat === 'number' &&
        typeof p.lng === 'number',
    );
    if (!isValidPoints) {
      return reply.code(400).send({ error: 'INVALID_POINT_FORMAT' });
    }

    try {
      const result = await sessionService.setPlayableArea(
        request.user.id,
        sessionId,
        polygonPoints,
      );
      return reply.send({ playableArea: result.playable_area });
    } catch (err) {
      if (err.message === 'SESSION_NOT_FOUND_OR_NOT_HOST') {
        return reply.code(403).send({ error: err.message });
      }
      if (err.message === 'INVALID_POLYGON') {
        return reply.code(400).send({ error: err.message });
      }
      throw err;
    }
  });

  fastify.patch('/:sessionId/fantasy-wars-layout', async (request, reply) => {
    const { sessionId } = request.params;
    const parsed = fantasyWarsLayoutSchema.safeParse(request.body || {});

    if (!parsed.success) {
      return reply.code(400).send({ error: 'INVALID_LAYOUT' });
    }

    try {
      const result = await sessionService.setFantasyWarsLayout(
        request.user.id,
        sessionId,
        parsed.data,
      );
      return reply.send({
        playableArea: result.playable_area,
        gameConfig: result.game_config,
      });
    } catch (err) {
      const errorMap = {
        SESSION_NOT_FOUND_OR_NOT_HOST: 403,
        INVALID_GAME_TYPE: 400,
        INVALID_POLYGON: 400,
        INVALID_CONTROL_POINTS: 400,
        INVALID_SPAWN_ZONES: 400,
      };
      return reply.code(errorMap[err.message] || 500).send({ error: err.message });
    }
  });

  fastify.patch('/:sessionId/fantasy-wars-duel-config', async (request, reply) => {
    const { sessionId } = request.params;
    const parsed = fantasyWarsDuelConfigSchema.safeParse(request.body || {});

    if (!parsed.success) {
      return reply.code(400).send({ error: 'INVALID_DUEL_CONFIG' });
    }

    try {
      const result = await sessionService.updateFantasyWarsDuelConfig(
        request.user.id,
        sessionId,
        parsed.data,
      );
      return reply.send({
        gameConfig: result.game_config,
      });
    } catch (err) {
      const errorMap = {
        SESSION_NOT_FOUND_OR_NOT_HOST: 403,
        INVALID_GAME_TYPE: 400,
      };
      return reply.code(errorMap[err.message] || 500).send({ error: err.message });
    }
  });

  fastify.post('/:sessionId/end', async (request, reply) => {
    try {
      const { sessionId } = request.params;
      await sessionService.endSession(request.user.id, sessionId);
      await Promise.all([
        cleanupAiHistory({ roomId: sessionId }),
        cleanupGameState(sessionId),
      ]);
      return reply.send({ message: 'Session ended' });
    } catch (err) {
      if (err.message === 'SESSION_NOT_FOUND_OR_NOT_HOST') {
        return reply.code(403).send({ error: err.message });
      }
      throw err;
    }
  });

  fastify.post('/join', async (request, reply) => {
    const { code } = request.body || {};
    if (!code || typeof code !== 'string') {
      return reply.code(400).send({ error: 'MISSING_SESSION_CODE' });
    }

    try {
      const session = await sessionService.joinSession(request.user.id, code);
      return reply.send({ session });
    } catch (err) {
      const errorMap = {
        SESSION_NOT_FOUND: 404,
        SESSION_ENDED: 410,
        SESSION_EXPIRED: 410,
        SESSION_FULL: 409,
        ALREADY_IN_SESSION: 409,
      };
      return reply.code(errorMap[err.message] || 500).send({ error: err.message });
    }
  });

  fastify.get('/', async (request, reply) => {
    const sessions = await sessionService.getMySessions(request.user.id);
    return reply.send({ sessions });
  });

  fastify.get('/:sessionId', async (request, reply) => {
    const { sessionId } = request.params;
    const members = await sessionService.getSessionMembers(sessionId);
    const isMember = members.some((member) => member.user_id === request.user.id);

    if (!isMember) {
      return reply.code(403).send({ error: 'NOT_A_MEMBER' });
    }

    const session = await sessionService.getSession(sessionId);
    return reply.send({
      session: {
        ...session,
        members,
      },
      members,
    });
  });

  fastify.delete('/:sessionId', async (request, reply) => {
    try {
      const { sessionId } = request.params;
      await sessionService.endSession(request.user.id, sessionId);
      await Promise.all([
        cleanupAiHistory({ roomId: sessionId }),
        cleanupGameState(sessionId),
      ]);
      return reply.send({ message: 'Session ended' });
    } catch (err) {
      if (err.message === 'SESSION_NOT_FOUND_OR_NOT_HOST') {
        return reply.code(403).send({ error: err.message });
      }
      throw err;
    }
  });

  fastify.post('/:sessionId/leave', async (request, reply) => {
    const { sessionId } = request.params;
    await sessionService.leaveSession(request.user.id, sessionId);
    await cleanupAiHistory({ roomId: sessionId, userId: request.user.id });
    return reply.send({ message: 'Left session' });
  });

  fastify.get('/:sessionId/track/:userId', async (request, reply) => {
    const { sessionId, userId } = request.params;
    const { from, to, limit } = request.query;

    const members = await sessionService.getSessionMembers(sessionId);
    const isMember = members.some((member) => member.user_id === request.user.id);
    if (!isMember) {
      return reply.code(403).send({ error: 'NOT_A_MEMBER' });
    }

    const track = await locationService.getTrackHistory(userId, sessionId, {
      from,
      to,
      limit: limit ? Math.min(Number(limit), 1000) : 500,
    });

    return reply.send({ track });
  });

  fastify.get('/:sessionId/distance', async (request, reply) => {
    const { sessionId } = request.params;
    const { userId1, userId2 } = request.query;

    if (!userId1 || !userId2) {
      return reply.code(400).send({ error: 'MISSING_USER_IDS' });
    }

    const distance = await locationService.getDistanceBetweenUsers(
      sessionId,
      userId1,
      userId2,
    );

    return reply.send({
      distance,
      unit: 'meters',
      available: distance !== null,
    });
  });

  fastify.patch('/:sessionId/members/:userId/team', async (request, reply) => {
    const { sessionId, userId: targetUserId } = request.params;
    const { teamId } = request.body || {};

    if (!teamId || typeof teamId !== 'string') {
      return reply.code(400).send({ error: 'INVALID_TEAM' });
    }

    try {
      const result = await sessionService.moveMemberToTeam(
        request.user.id,
        sessionId,
        targetUserId,
        teamId,
      );

      const io = getIo();
      if (io) {
        io.to(`session:${sessionId}`).emit(EVENTS.MEMBER_UPDATED, {
          userId: targetUserId,
          teamId: result.team_id,
          sessionId,
          updatedBy: request.user.id,
        });
      }

      return reply.send({ teamId: result.team_id });
    } catch (err) {
      const errorMap = {
        PERMISSION_DENIED: 403,
        TARGET_NOT_A_MEMBER: 404,
        SESSION_NOT_FOUND: 404,
        INVALID_TEAM: 400,
        INVALID_GAME_TYPE: 400,
      };
      return reply.code(errorMap[err.message] || 500).send({ error: err.message });
    }
  });

  fastify.delete('/:sessionId/members/:userId', async (request, reply) => {
    const { sessionId, userId: targetUserId } = request.params;

    try {
      await sessionService.kickMember(request.user.id, sessionId, targetUserId);
      await cleanupAiHistory({ roomId: sessionId, userId: targetUserId });

      const io = getIo();
      if (io) {
        io.to(`user:${targetUserId}`).emit(EVENTS.KICKED, {
          sessionId,
          by: request.user.id,
        });
        io.to(`session:${sessionId}`)
          .except(`user:${targetUserId}`)
          .emit(EVENTS.MEMBER_LEFT, {
            userId: targetUserId,
            reason: 'kicked',
            timestamp: Date.now(),
          });
      }

      return reply.send({ message: 'Member kicked' });
    } catch (err) {
      const errorMap = {
        PERMISSION_DENIED: 403,
        CANNOT_KICK_YOURSELF: 400,
        CANNOT_KICK_HOST: 400,
        TARGET_NOT_A_MEMBER: 404,
        SESSION_NOT_FOUND: 404,
      };
      return reply.code(errorMap[err.message] || 500).send({ error: err.message });
    }
  });

  fastify.post('/:sessionId/start', async (request, reply) => {
    const { sessionId } = request.params;

    try {
      const io = getIo();
      if (!io) {
        return reply.code(503).send({ error: 'SOCKET_SERVER_UNAVAILABLE' });
      }

      const { startedPayload } = await startGameForSession({
        io,
        sessionId,
        requesterUserId: request.user.id,
      });

      return reply.send({
        started: true,
        sessionId,
        ...startedPayload,
      });
    } catch (err) {
      if (err.message === 'SESSION_NOT_FOUND') {
        return reply.code(404).send({ error: err.message });
      }
      if (err.message === 'NOT_HOST') {
        return reply.code(403).send({ error: err.message });
      }
      if (err.message === 'GAME_ALREADY_STARTED') {
        return reply.code(409).send({ error: err.message });
      }
      if (err.message === 'NOT_ENOUGH_PLAYERS') {
        return reply.code(400).send({
          error: err.message,
          ...(err.details ?? {}),
        });
      }
      if (
        err.message === 'FANTASY_WARS_NOT_ENOUGH_PLAYERS' ||
        err.message === 'FANTASY_WARS_TEAM_ASSIGNMENT_REQUIRED' ||
        err.message === 'FANTASY_WARS_TEAM_SIZE_TOO_SMALL' ||
        err.message === 'FANTASY_WARS_PLAYABLE_AREA_REQUIRED' ||
        err.message === 'FANTASY_WARS_CONTROL_POINTS_REQUIRED' ||
        err.message === 'FANTASY_WARS_SPAWN_ZONES_REQUIRED' ||
        err.message === 'CONTROL_POINT_LOCATIONS_REQUIRED'
      ) {
        return reply.code(400).send({
          error: err.message,
          ...(err.details ?? {}),
        });
      }
      throw err;
    }
  });

  fastify.patch('/:sessionId/sharing', async (request, reply) => {
    const { enabled } = request.body || {};
    if (typeof enabled !== 'boolean') {
      return reply.code(400).send({ error: 'MISSING_ENABLED_FIELD' });
    }

    await locationService.toggleSharing(
      request.user.id,
      request.params.sessionId,
      enabled,
    );
    return reply.send({ sharing_enabled: enabled });
  });
}
