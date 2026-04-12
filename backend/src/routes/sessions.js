// src/routes/sessions.js
import { z } from 'zod';
import { authenticate } from '../middleware/auth.js';
import * as sessionService from '../services/sessionService.js';
import * as locationService from '../services/locationService.js';
import { getIo, EVENTS } from '../websocket/index.js';
import { setCache } from '../config/redis.js';

const createSessionSchema = z.object({
  name:          z.string().max(100).optional(),
  activeModules: z.array(z.string()).max(10).optional(),
  durationHours: z.number().min(1).max(72).optional(),
  maxMembers:    z.number().min(2).max(50).optional(),
  gameType:      z.string().optional(),
  // 게임별 설정
  impostorCount:  z.number().min(1).max(3).optional(),
  killCooldown:   z.number().min(10).max(60).optional(),
  discussionTime: z.number().min(30).max(180).optional(),
  voteTime:       z.number().min(15).max(60).optional(),
  missionPerCrew: z.number().min(1).max(5).optional(),
});

export default async function sessionRoutes(fastify) {
  // Flutter 클라이언트가 Content-Type: application/json + 빈 body로 요청하는 경우 처리
  // (예: POST /:sessionId/leave) — FST_ERR_CTP_EMPTY_JSON_BODY 방지
  fastify.removeContentTypeParser('application/json');
  fastify.addContentTypeParser('application/json', { parseAs: 'string' }, (req, body, done) => {
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
  });

  // 모든 세션 라우트는 인증 필요
  fastify.addHook('preHandler', authenticate);

  // ── POST /sessions ───────────────────────────────────────────────────────
  // 세션 생성 (호스트가 됨)
  fastify.post('/', async (request, reply) => {
    const parsed = createSessionSchema.safeParse(request.body || {});
    if (!parsed.success) {
      return reply.code(400).send({ error: 'VALIDATION_ERROR' });
    }

    const session = await sessionService.createSession(request.user.id, parsed.data);
    return reply.code(201).send({ session });
  });

  // ── POST /sessions/:sessionId/end ────────────────────────────────────────
  // 세션 종료 (POST 방식, 호스트만) — DELETE와 동일 기능, 클라이언트 호환성 추가
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

  // ── POST /sessions/join ──────────────────────────────────────────────────
  // 초대 코드로 세션 참가
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
        SESSION_ENDED:     410,
        SESSION_EXPIRED:   410,
        SESSION_FULL:      409,
        ALREADY_IN_SESSION: 409,
      };
      return reply.code(errorMap[err.message] || 500).send({ error: err.message });
    }
  });

  // ── GET /sessions ────────────────────────────────────────────────────────
  // 내가 참가 중인 세션 목록
  fastify.get('/', async (request, reply) => {
    const sessions = await sessionService.getMySessions(request.user.id);
    return reply.send({ sessions });
  });

  // ── GET /sessions/:sessionId ─────────────────────────────────────────────
  // 세션 상세 (멤버 목록 + 각 멤버 최신 위치)
  fastify.get('/:sessionId', async (request, reply) => {
    const { sessionId } = request.params;

    const members = await sessionService.getSessionMembers(sessionId);

    // 현재 유저가 이 세션 멤버인지 확인
    const isMember = members.some((m) => m.user_id === request.user.id);
    if (!isMember) {
      return reply.code(403).send({ error: 'NOT_A_MEMBER' });
    }

    // 세션 기본 정보도 함께 반환
    const session = await sessionService.getSession(sessionId);
    return reply.send({
      session: {
        ...session,
        members,
      },
      members, // 하위 호환성 유지
    });
  });

  // ── DELETE /sessions/:sessionId ──────────────────────────────────────────
  // 세션 종료 (호스트만)
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

  // ── POST /sessions/:sessionId/leave ─────────────────────────────────────
  // 세션 나가기
  fastify.post('/:sessionId/leave', async (request, reply) => {
    await sessionService.leaveSession(request.user.id, request.params.sessionId);
    return reply.send({ message: 'Left session' });
  });

  // ── GET /sessions/:sessionId/track/:userId ───────────────────────────────
  // 특정 멤버 이동 경로 히스토리 조회
  fastify.get('/:sessionId/track/:userId', async (request, reply) => {
    const { sessionId, userId } = request.params;
    const { from, to, limit } = request.query;

    // 세션 멤버인지 확인
    const members = await sessionService.getSessionMembers(sessionId);
    const isMember = members.some((m) => m.user_id === request.user.id);
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

  // ── GET /sessions/:sessionId/distance ────────────────────────────────────
  // 두 사용자 간 현재 거리
  fastify.get('/:sessionId/distance', async (request, reply) => {
    const { sessionId } = request.params;
    const { userId1, userId2 } = request.query;

    if (!userId1 || !userId2) {
      return reply.code(400).send({ error: 'MISSING_USER_IDS' });
    }

    const distance = await locationService.getDistanceBetweenUsers(
      sessionId, userId1, userId2
    );

    return reply.send({
      distance,
      unit: 'meters',
      available: distance !== null,
    });
  });

  // ── PATCH /sessions/:sessionId/members/:userId/role ─────────────────────
  // 멤버 역할 변경 (host/admin만)
  fastify.patch('/:sessionId/members/:userId/role', async (request, reply) => {
    const { sessionId, userId: targetUserId } = request.params;
    const { role: newRole } = request.body || {};

    if (!['admin', 'member'].includes(newRole)) {
      return reply.code(400).send({ error: 'INVALID_ROLE' });
    }

    try {
      await sessionService.updateMemberRole(
        request.user.id, sessionId, targetUserId, newRole
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
        PERMISSION_DENIED:        403,
        CANNOT_CHANGE_OWN_ROLE:   400,
        CANNOT_CHANGE_HOST_ROLE:  400,
        TARGET_NOT_A_MEMBER:      404,
        SESSION_NOT_FOUND:        404,
        INVALID_ROLE:             400,
      };
      return reply.code(errorMap[err.message] || 500).send({ error: err.message });
    }
  });

  // ── DELETE /sessions/:sessionId/members/:userId ──────────────────────────
  // 멤버 강제 퇴장 (host/admin만)
  fastify.delete('/:sessionId/members/:userId', async (request, reply) => {
    const { sessionId, userId: targetUserId } = request.params;

    try {
      await sessionService.kickMember(request.user.id, sessionId, targetUserId);

      const io = getIo();
      if (io) {
        // 강퇴 대상에게 kicked 이벤트 (개인 룸)
        io.to(`user:${targetUserId}`).emit(EVENTS.KICKED, {
          sessionId,
          by: request.user.id,
        });
        // 세션 전체에 member:left 브로드캐스트 (강퇴 대상 제외)
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
        PERMISSION_DENIED:      403,
        CANNOT_KICK_YOURSELF:   400,
        CANNOT_KICK_HOST:       400,
        TARGET_NOT_A_MEMBER:    404,
        SESSION_NOT_FOUND:      404,
      };
      return reply.code(errorMap[err.message] || 500).send({ error: err.message });
    }
  });

  // ── POST /sessions/:sessionId/start ─────────────────────────────────────
  // 게임 시작 (호스트만, 최소 인원 검증 후 game:started 이벤트 emit)
  fastify.post('/:sessionId/start', async (request, reply) => {
    const { sessionId } = request.params;

    const session = await sessionService.getSession(sessionId);
    if (!session) {
      return reply.code(404).send({ error: 'SESSION_NOT_FOUND' });
    }
    if (session.host_user_id !== request.user.id) {
      return reply.code(403).send({ error: 'NOT_HOST' });
    }

    const members = await sessionService.getSessionMembers(sessionId);
    const activeModules = session.active_modules || [];

    // 게임 타입별 최소 인원 검증: 모듈 없음 → 2명, 그 외 → 4명
    const minPlayers = activeModules.length === 0 ? 2 : 4;
    if (members.length < minPlayers) {
      return reply.code(400).send({
        error: 'NOT_ENOUGH_PLAYERS',
        required: minPlayers,
        current: members.length,
      });
    }

    // Redis에 게임 시작 상태 저장 (세션 만료 시간까지 유지)
    await setCache(`game:${sessionId}:started`, true, 86400);

    const io = getIo();
    if (io) {
      io.to(`session:${sessionId}`).emit(EVENTS.GAME_STARTED, {
        sessionId,
        startedAt:     new Date().toISOString(),
        activeModules: activeModules,
      });
    }

    return reply.send({ started: true, sessionId });
  });

  // ── PATCH /sessions/:sessionId/sharing ───────────────────────────────────
  // 내 위치 공유 ON/OFF
  fastify.patch('/:sessionId/sharing', async (request, reply) => {
    const { enabled } = request.body || {};
    if (typeof enabled !== 'boolean') {
      return reply.code(400).send({ error: 'MISSING_ENABLED_FIELD' });
    }

    await locationService.toggleSharing(request.user.id, request.params.sessionId, enabled);
    return reply.send({ sharing_enabled: enabled });
  });
}
