// src/routes/sessions.js
import { z } from 'zod';
import { authenticate } from '../middleware/auth.js';
import * as sessionService from '../services/sessionService.js';
import * as locationService from '../services/locationService.js';
import { getIo, EVENTS } from '../websocket/index.js';
import { startGameForSession } from '../game/startGameService.js';

const createSessionSchema = z.object({
  name: z.string().max(100).optional(),
  activeModules: z.array(z.string()).max(10).optional(),
  durationHours: z.number().min(1).max(72).optional(),
  maxMembers: z.number().min(2).max(50).optional(),
  gameType: z.string().optional(),
  impostorCount: z.number().min(1).max(3).optional(),
  killCooldown: z.number().min(10).max(60).optional(),
  discussionTime: z.number().min(30).max(180).optional(),
  voteTime: z.number().min(15).max(60).optional(),
  missionPerCrew: z.number().min(1).max(5).optional(),
});

const normalizeCreateSessionBody = (body = {}) => ({
  ...body,
  activeModules: body.activeModules ?? body.active_modules,
});

export default async function sessionRoutes(fastify) {
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

  fastify.post('/:sessionId/end', async (request, reply) => {
    try {
      await sessionService.endSession(request.user.id, request.params.sessionId);
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
      await sessionService.endSession(request.user.id, request.params.sessionId);
      return reply.send({ message: 'Session ended' });
    } catch (err) {
      if (err.message === 'SESSION_NOT_FOUND_OR_NOT_HOST') {
        return reply.code(403).send({ error: err.message });
      }
      throw err;
    }
  });

  fastify.post('/:sessionId/leave', async (request, reply) => {
    await sessionService.leaveSession(request.user.id, request.params.sessionId);
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

  fastify.patch('/:sessionId/members/:userId/role', async (request, reply) => {
    const { sessionId, userId: targetUserId } = request.params;
    const { role: newRole } = request.body || {};

    if (!['admin', 'member'].includes(newRole)) {
      return reply.code(400).send({ error: 'INVALID_ROLE' });
    }

    try {
      await sessionService.updateMemberRole(
        request.user.id,
        sessionId,
        targetUserId,
        newRole,
      );

      const io = getIo();
      if (io) {
        io.to(`session:${sessionId}`).emit(EVENTS.ROLE_CHANGED, {
          userId: targetUserId,
          role: newRole,
          sessionId,
          updatedBy: request.user.id,
        });
      }

      return reply.send({ role: newRole });
    } catch (err) {
      const errorMap = {
        PERMISSION_DENIED: 403,
        CANNOT_CHANGE_OWN_ROLE: 400,
        CANNOT_CHANGE_HOST_ROLE: 400,
        TARGET_NOT_A_MEMBER: 404,
        SESSION_NOT_FOUND: 404,
        INVALID_ROLE: 400,
      };
      return reply.code(errorMap[err.message] || 500).send({ error: err.message });
    }
  });

  fastify.delete('/:sessionId/members/:userId', async (request, reply) => {
    const { sessionId, userId: targetUserId } = request.params;

    try {
      await sessionService.kickMember(request.user.id, sessionId, targetUserId);

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
      if (err.message === 'NOT_ENOUGH_PLAYERS') {
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
