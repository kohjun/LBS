// src/websocket/index.js
import { Server } from 'socket.io';
import { verifySocketToken } from '../middleware/auth.js';
import { redisClient } from '../config/redis.js';
import * as locationService from '../services/locationService.js';
import * as sessionService from '../services/sessionService.js';
import { sendSosAlert, sendGeofenceAlert } from '../services/fcmService.js';
import { checkGeofences } from '../services/geofenceService.js';

// ─────────────────────────────────────────────────────────────────────────────
// Socket.IO 이벤트 상수 (클라이언트와 공유하는 프로토콜)
// ─────────────────────────────────────────────────────────────────────────────
export const EVENTS = {
  // Client → Server
  JOIN_SESSION:        'session:join',
  LEAVE_SESSION:       'session:leave',
  LOCATION_UPDATE:     'location:update',
  STATUS_UPDATE:       'status:update',
  SOS_TRIGGER:         'sos:trigger',
  ACTION_INTERACT:     'action:interact',
  GAME_START:          'game:start',
  GAME_REQUEST_STATE:  'game:request_state',

  // Server → Client
  SESSION_JOINED:     'session:joined',
  MEMBER_JOINED:      'member:joined',
  MEMBER_LEFT:        'member:left',
  LOCATION_CHANGED:   'location:changed',    // 다른 멤버 위치 수신
  STATUS_CHANGED:     'status:changed',
  SOS_ALERT:          'sos:alert',
  SESSION_SNAPSHOT:   'session:snapshot',    // 첫 연결 시 전체 상태
  KICKED:             'kicked',              // 강제 퇴장
  ROLE_CHANGED:       'role_changed',        // 역할 변경 브로드캐스트
  ACTION_RESULT:      'action:result',
  MODULE_ERROR:       'module:error',
  PLAYER_ELIMINATED:  'player:eliminated',
  GAME_OVER:          'game:over',
  GAME_STATE_UPDATE:  'game:state_update',
  TAG_ASSIGNED:       'tag:assigned',
  TAG_TRANSFERRED:    'tag:transferred',
  TAG_STATE_UPDATE:   'tag:state_update',
  ROUND_START:        'round:start',
  ROUND_END:          'round:end',
  VOTE_OPEN:          'vote:open',
  VOTE_CAST:          'vote:cast',
  VOTE_RESULT:        'vote:result',
  ERROR:              'error',
};

// ─────────────────────────────────────────────────────────────────────────────
// 모듈 레지스트리 및 세션 타입 정의
// ─────────────────────────────────────────────────────────────────────────────
export const MODULE_REGISTRY = {
  proximity: ['chase'],
  tag:       ['chase'],
  team:      ['chase', 'verbal'],
  vote:      ['verbal'],
  round:     ['verbal'],
  mission:   ['location'],
  item:      ['location'],
};

export const SESSION_TYPES = {
  default:  { modules: [] },
  chase:    { modules: ['proximity', 'tag', 'team'] },
  verbal:   { modules: ['vote', 'round', 'team'] },
  location: { modules: ['mission', 'item'] },
};

// ─────────────────────────────────────────────────────────────────────────────
// io 인스턴스 참조 (routes에서 WebSocket 이벤트 발행 시 사용)
// ─────────────────────────────────────────────────────────────────────────────
let _io = null;
export const getIo = () => _io;

// ─────────────────────────────────────────────────────────────────────────────
// Socket.IO 서버 초기화
// ─────────────────────────────────────────────────────────────────────────────
export const createSocketServer = (httpServer) => {
  _io = new Server(httpServer, {
    cors: {
      origin: process.env.ALLOWED_ORIGINS?.split(',') || '*',
      credentials: true,
    },
    // 연결 안정성 설정
    pingTimeout: 60000,
    pingInterval: 25000,
    transports: ['websocket', 'polling'],
  });
  const io = _io; // 함수 내 로컬 별칭 (기존 코드 호환)

  // ── 전역 인증 미들웨어 ─────────────────────────────────────────────────
  // 모든 소켓 연결 전에 JWT 검증
  io.use(async (socket, next) => {
    try {
      const token =
        socket.handshake.auth?.token ||          // { auth: { token } }
        socket.handshake.query?.token;            // ?token=xxx (Fallback)

      const user = verifySocketToken(token);
      socket.user = user;  // socket.user.id, socket.user.nickname 사용 가능
      next();
    } catch (err) {
      next(new Error('AUTH_FAILED'));
    }
  });

  // ── 소켓 연결 핸들러 ─────────────────────────────────────────────────
  io.on('connection', (socket) => {
    const userId = socket.user.id;
    console.log(`[WS] Connected: ${socket.user.nickname} (${userId})`);

    // 사용자 전용 룸 (개인 알림용)
    socket.join(`user:${userId}`);

    // ── session:join ──────────────────────────────────────────────────
    socket.on(EVENTS.JOIN_SESSION, async ({ sessionId }) => {
      if (!sessionId) {
        return socket.emit(EVENTS.ERROR, { code: 'MISSING_SESSION_ID' });
      }

      try {
        // 멤버 목록 확인 (세션에 속해 있는지)
        const members = await sessionService.getSessionMembers(sessionId);
        const isMember = members.some((m) => m.user_id === userId);
        if (!isMember) {
          return socket.emit(EVENTS.ERROR, { code: 'NOT_A_MEMBER' });
        }

        const roomName = `session:${sessionId}`;
        socket.join(roomName);
        socket.currentSessionId = sessionId;

        // 현재 세션의 모든 멤버 위치 스냅샷 전송 (초기 동기화)
        const memberIds = members.map((m) => m.user_id);
        const snapshot = await locationService.getSessionSnapshot(sessionId, memberIds);

        socket.emit(EVENTS.SESSION_SNAPSHOT, {
          sessionId,
          members,
          locations: snapshot,
        });

        // 다른 멤버에게 입장 알림
        socket.to(roomName).emit(EVENTS.MEMBER_JOINED, {
          userId,
          nickname: socket.user.nickname,
          timestamp: Date.now(),
        });

        socket.emit(EVENTS.SESSION_JOINED, { sessionId, memberCount: members.length });

      } catch (err) {
        console.error('[WS] join error:', err);
        socket.emit(EVENTS.ERROR, { code: 'JOIN_FAILED' });
      }
    });

    // ── location:update ───────────────────────────────────────────────
    // 클라이언트 GPS 위치 수신 → 저장 → 같은 세션 멤버에게 브로드캐스트
    socket.on(EVENTS.LOCATION_UPDATE, async (payload) => {
      const sessionId = socket.currentSessionId || payload.sessionId;
      if (!sessionId) return;

      const { lat, lng, accuracy, altitude, speed, heading, source, battery, status } = payload;

      // 기본 유효성 검사
      if (typeof lat !== 'number' || typeof lng !== 'number') return;
      if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return;

      try {
        const saved = await locationService.saveLocation(userId, sessionId, {
          lat, lng, accuracy, altitude, speed, heading,
          source: source || 'gps',
          battery,
          status: status || 'moving',
        });

        // 근접 거리 계산용 컴팩트 위치 캐시 (5분 TTL) — 별도 키로 메인 캐시 TTL 보호
        await redisClient.set(
          `prox:${sessionId}:${userId}`,
          JSON.stringify({ lat, lng }),
          { EX: 300 }
        );

        const broadcastData = {
          userId,
          sessionId,
          nickname: socket.user.nickname,
          ...saved,
        };

        // Redis Pub/Sub으로 발행 (수평 확장 대응)
        await redisClient.publish(
          `location:${sessionId}:${userId}`,
          JSON.stringify(broadcastData)
        );

        // 같은 서버 인스턴스 내 즉시 브로드캐스트 (레이턴시 최소화)
        socket.to(`session:${sessionId}`).emit(EVENTS.LOCATION_CHANGED, broadcastData);

        // 지오펜스 진입/이탈 감지 (비동기, 메인 흐름 블로킹 없음)
        checkGeofences(userId, sessionId, lat, lng)
          .then(({ entered, exited }) => {
            if (entered.length > 0) {
              sendGeofenceAlert({
                sessionId,
                userId,
                nickname:   socket.user.nickname,
                geofences:  entered,
                eventType:  'enter',
              }).catch((e) => console.error('[WS] FCM geofence enter error:', e));
            }
            if (exited.length > 0) {
              sendGeofenceAlert({
                sessionId,
                userId,
                nickname:   socket.user.nickname,
                geofences:  exited,
                eventType:  'exit',
              }).catch((e) => console.error('[WS] FCM geofence exit error:', e));
            }
          })
          .catch((e) => console.error('[WS] checkGeofences error:', e));

      } catch (err) {
        console.error('[WS] location update error:', err);
      }
    });

    // ── action:interact ───────────────────────────────────────────────
    // 모듈 기반 게임 액션 처리 (예: PROXIMITY_KILL, VOTE, MISSION 등)
    socket.on(EVENTS.ACTION_INTERACT, async ({ sessionId: sid, actionType, targetUserId }) => {
      const sessionId = sid || socket.currentSessionId;
      if (!sessionId || !actionType) {
        return socket.emit(EVENTS.MODULE_ERROR, { code: 'MISSING_FIELDS' });
      }

      try {
        const session = await sessionService.getSession(sessionId);
        if (!session) {
          return socket.emit(EVENTS.MODULE_ERROR, { code: 'SESSION_NOT_FOUND' });
        }

        const activeModules = session.active_modules || [];

        if (actionType === 'PROXIMITY_KILL') {
          if (!activeModules.includes('PROXIMITY_ACTION')) {
            return socket.emit(EVENTS.MODULE_ERROR, { code: 'MODULE_NOT_ACTIVE' });
          }

          if (!targetUserId) {
            return socket.emit(EVENTS.MODULE_ERROR, { code: 'MISSING_FIELDS' });
          }

          // 두 유저의 최신 위치 조회: prox 캐시 → 메인 캐시 → Hash 폴백
          const resolveLocation = async (uid) => {
            const prox = await redisClient.get(`prox:${sessionId}:${uid}`);
            if (prox) return JSON.parse(prox);
            const main = await redisClient.get(`location:${sessionId}:${uid}`);
            if (main) return JSON.parse(main);
            const hash = await redisClient.hGetAll(`session:${sessionId}:user:${uid}:state`);
            if (hash && hash.lat && hash.lng) {
              return { lat: parseFloat(hash.lat), lng: parseFloat(hash.lng) };
            }
            return null;
          };

          const [actorLoc, targetLoc] = await Promise.all([
            resolveLocation(userId),
            resolveLocation(targetUserId),
          ]);

          if (!actorLoc || !targetLoc) {
            return socket.emit(EVENTS.ACTION_RESULT, {
              actionType, sessionId, status: 'failed', reason: 'LOCATION_UNAVAILABLE',
            });
          }

          // Haversine 거리 계산 (미터)
          const toRad = (d) => (d * Math.PI) / 180;
          const R = 6371000;
          const dLat = toRad(targetLoc.lat - actorLoc.lat);
          const dLng = toRad(targetLoc.lng - actorLoc.lng);
          const a =
            Math.sin(dLat / 2) ** 2 +
            Math.cos(toRad(actorLoc.lat)) * Math.cos(toRad(targetLoc.lat)) *
            Math.sin(dLng / 2) ** 2;
          const distance = R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));

          if (distance > 15) {
            return socket.emit(EVENTS.ACTION_RESULT, {
              actionType, sessionId, status: 'failed', reason: 'TOO_FAR',
            });
          }

          // 중복 처리 방지: SET NX 2초 락
          const lockKey = `kill_lock:${sessionId}:${userId}:${targetUserId}`;
          const locked = await redisClient.set(lockKey, '1', { NX: true, EX: 2 });
          if (!locked) return; // 이미 처리 중인 킬 이벤트

          // ── Tag 모듈 활성 시: 킬 대신 태그 전달 ────────────────────────
          if (activeModules.includes('tag')) {
            await redisClient.set(`tag:${sessionId}:tagger`, userId, { EX: 86400 });

            socket.emit(EVENTS.ACTION_RESULT, {
              actionType,
              sessionId,
              targetUserId,
              status: 'success',
            });

            io.to(`session:${sessionId}`).emit(EVENTS.TAG_TRANSFERRED, {
              newTaggerId:      userId,
              previousTaggerId: targetUserId,
              sessionId,
              timestamp:        Date.now(),
            });

            return;
          }

          // ── 일반 킬 처리 ─────────────────────────────────────────────────
          // 탈락 상태를 Redis에 영속 (24시간)
          await redisClient.set(`eliminated:${sessionId}:${targetUserId}`, '1', { EX: 86400 });

          // 액터에게 성공 응답
          socket.emit(EVENTS.ACTION_RESULT, {
            actionType,
            sessionId,
            targetUserId,
            status: 'success',
          });

          // 타겟 개인 룸에 제거 이벤트 전송
          io.to(`user:${targetUserId}`).emit('proximity:killed', {
            killedBy: userId,
            nickname: socket.user.nickname,
            sessionId,
          });

          // 세션 전체에 탈락 브로드캐스트
          io.to(`session:${sessionId}`).emit(EVENTS.PLAYER_ELIMINATED, {
            userId:    targetUserId,
            killedBy:  userId,
            nickname:  socket.user.nickname,
            sessionId,
            timestamp: Date.now(),
          });

          // 게임 상태 갱신 (게임이 진행 중인 경우만)
          const gameRaw = await redisClient.get(`game:${sessionId}`);
          if (gameRaw) {
            const gameState = JSON.parse(gameRaw);
            if (gameState.status === 'in_progress') {
              gameState.alivePlayerIds = gameState.alivePlayerIds.filter(
                (id) => id !== targetUserId
              );

              if (gameState.alivePlayerIds.length === 1) {
                // 마지막 생존자 → 게임 종료
                gameState.status = 'finished';
                gameState.finishedAt = Date.now();
                await redisClient.set(
                  `game:${sessionId}`,
                  JSON.stringify(gameState),
                  { EX: 86400 }
                );
                io.to(`session:${sessionId}`).emit(EVENTS.GAME_OVER, {
                  winnerId:  gameState.alivePlayerIds[0],
                  sessionId,
                  timestamp: Date.now(),
                });
              } else {
                // 게임 계속 진행
                await redisClient.set(
                  `game:${sessionId}`,
                  JSON.stringify(gameState),
                  { EX: 86400 }
                );
                io.to(`session:${sessionId}`).emit(EVENTS.GAME_STATE_UPDATE, {
                  sessionId,
                  status:         gameState.status,
                  aliveCount:     gameState.alivePlayerIds.length,
                  alivePlayerIds: gameState.alivePlayerIds,
                });
              }
            }
          }
        }
      } catch (err) {
        console.error('[WS] action:interact error:', err);
        socket.emit(EVENTS.MODULE_ERROR, { code: 'INTERNAL_ERROR' });
      }
    });

    // ── game:start ────────────────────────────────────────────────────
    // 호스트만 게임을 시작할 수 있음
    socket.on(EVENTS.GAME_START, async ({ sessionId: sid } = {}) => {
      const sessionId = sid || socket.currentSessionId;
      if (!sessionId) {
        return socket.emit(EVENTS.MODULE_ERROR, { code: 'MISSING_SESSION_ID' });
      }

      try {
        const session = await sessionService.getSession(sessionId);
        if (!session) {
          return socket.emit(EVENTS.MODULE_ERROR, { code: 'SESSION_NOT_FOUND' });
        }

        if (session.host_user_id !== userId) {
          return socket.emit(EVENTS.MODULE_ERROR, { code: 'PERMISSION_DENIED' });
        }

        // 현재 세션 멤버 전원을 생존자로 등록
        const members = await sessionService.getSessionMembers(sessionId);
        const alivePlayerIds = members.map((m) => m.user_id);

        const gameState = {
          status:         'in_progress',
          startedAt:      Date.now(),
          alivePlayerIds,
        };

        await redisClient.set(
          `game:${sessionId}`,
          JSON.stringify(gameState),
          { EX: 86400 }
        );

        io.to(`session:${sessionId}`).emit(EVENTS.GAME_STATE_UPDATE, {
          sessionId,
          status:         gameState.status,
          startedAt:      gameState.startedAt,
          aliveCount:     alivePlayerIds.length,
          alivePlayerIds,
        });

        // ── Tag 모듈: 초기 태거 랜덤 지정 ──────────────────────────────
        if ((session.active_modules || []).includes('tag')) {
          const taggerId = alivePlayerIds[Math.floor(Math.random() * alivePlayerIds.length)];
          await redisClient.set(`tag:${sessionId}:tagger`, taggerId, { EX: 86400 });
          io.to(`session:${sessionId}`).emit(EVENTS.TAG_ASSIGNED, {
            taggerId,
            sessionId,
          });
        }

      } catch (err) {
        console.error('[WS] game:start error:', err);
        socket.emit(EVENTS.MODULE_ERROR, { code: 'INTERNAL_ERROR' });
      }
    });

    // ── game:request_state ────────────────────────────────────────────
    // 재연결 등에서 현재 게임 상태를 요청하는 소켓에게만 응답
    socket.on(EVENTS.GAME_REQUEST_STATE, async ({ sessionId: sid } = {}) => {
      const sessionId = sid || socket.currentSessionId;
      if (!sessionId) return;

      try {
        const gameRaw = await redisClient.get(`game:${sessionId}`);
        if (!gameRaw) {
          return socket.emit(EVENTS.GAME_STATE_UPDATE, {
            sessionId,
            status: 'none',
          });
        }

        const [gameState, taggerId] = await Promise.all([
          Promise.resolve(JSON.parse(gameRaw)),
          redisClient.get(`tag:${sessionId}:tagger`),
        ]);

        socket.emit(EVENTS.GAME_STATE_UPDATE, {
          sessionId,
          status:         gameState.status,
          startedAt:      gameState.startedAt,
          finishedAt:     gameState.finishedAt,
          aliveCount:     gameState.alivePlayerIds.length,
          alivePlayerIds: gameState.alivePlayerIds,
          taggerId:       taggerId ?? null,
        });

      } catch (err) {
        console.error('[WS] game:request_state error:', err);
      }
    });

    // ── round:start ───────────────────────────────────────────────────
    socket.on(EVENTS.ROUND_START, async ({ sessionId: sid } = {}) => {
      const sessionId = sid || socket.currentSessionId;
      if (!sessionId) return socket.emit(EVENTS.MODULE_ERROR, { code: 'MISSING_SESSION_ID' });

      try {
        const session = await sessionService.getSession(sessionId);
        if (!session) return socket.emit(EVENTS.MODULE_ERROR, { code: 'SESSION_NOT_FOUND' });
        if (session.host_user_id !== userId) return socket.emit(EVENTS.MODULE_ERROR, { code: 'PERMISSION_DENIED' });

        const gameRaw = await redisClient.get(`game:${sessionId}`);
        if (!gameRaw) return socket.emit(EVENTS.MODULE_ERROR, { code: 'GAME_NOT_STARTED' });

        const currentRaw = await redisClient.get(`round:${sessionId}:current`);
        const roundNumber = (parseInt(currentRaw ?? '0', 10) || 0) + 1;
        await redisClient.set(`round:${sessionId}:current`, String(roundNumber), { EX: 86400 });

        const roundState = {
          roundNumber,
          phase:     'discussing',
          startedAt: Date.now(),
          votes:     {},
        };
        await redisClient.set(
          `round:${sessionId}:${roundNumber}`,
          JSON.stringify(roundState),
          { EX: 86400 }
        );

        io.to(`session:${sessionId}`).emit(EVENTS.ROUND_START, { sessionId, ...roundState });

      } catch (err) {
        console.error('[WS] round:start error:', err);
        socket.emit(EVENTS.MODULE_ERROR, { code: 'INTERNAL_ERROR' });
      }
    });

    // ── vote:open ─────────────────────────────────────────────────────
    socket.on(EVENTS.VOTE_OPEN, async ({ sessionId: sid, prompt } = {}) => {
      const sessionId = sid || socket.currentSessionId;
      if (!sessionId) return socket.emit(EVENTS.MODULE_ERROR, { code: 'MISSING_SESSION_ID' });

      try {
        const session = await sessionService.getSession(sessionId);
        if (!session) return socket.emit(EVENTS.MODULE_ERROR, { code: 'SESSION_NOT_FOUND' });
        if (session.host_user_id !== userId) return socket.emit(EVENTS.MODULE_ERROR, { code: 'PERMISSION_DENIED' });

        const currentRaw = await redisClient.get(`round:${sessionId}:current`);
        if (!currentRaw) return socket.emit(EVENTS.MODULE_ERROR, { code: 'NO_ACTIVE_ROUND' });

        const roundNumber = parseInt(currentRaw, 10);
        const roundRaw = await redisClient.get(`round:${sessionId}:${roundNumber}`);
        if (!roundRaw) return socket.emit(EVENTS.MODULE_ERROR, { code: 'ROUND_NOT_FOUND' });

        const roundState = JSON.parse(roundRaw);
        roundState.phase = 'voting';
        await redisClient.set(
          `round:${sessionId}:${roundNumber}`,
          JSON.stringify(roundState),
          { EX: 86400 }
        );

        io.to(`session:${sessionId}`).emit(EVENTS.VOTE_OPEN, {
          sessionId,
          roundNumber,
          prompt: prompt ?? '',
        });

      } catch (err) {
        console.error('[WS] vote:open error:', err);
        socket.emit(EVENTS.MODULE_ERROR, { code: 'INTERNAL_ERROR' });
      }
    });

    // ── vote:cast ─────────────────────────────────────────────────────
    socket.on(EVENTS.VOTE_CAST, async ({ sessionId: sid, roundNumber, targetUserId } = {}) => {
      const sessionId = sid || socket.currentSessionId;
      if (!sessionId || roundNumber == null || !targetUserId) {
        return socket.emit(EVENTS.MODULE_ERROR, { code: 'MISSING_FIELDS' });
      }

      try {
        const roundRaw = await redisClient.get(`round:${sessionId}:${roundNumber}`);
        if (!roundRaw) return socket.emit(EVENTS.MODULE_ERROR, { code: 'ROUND_NOT_FOUND' });

        const roundState = JSON.parse(roundRaw);
        roundState.votes[userId] = targetUserId;
        await redisClient.set(
          `round:${sessionId}:${roundNumber}`,
          JSON.stringify(roundState),
          { EX: 86400 }
        );

        const votedCount = Object.keys(roundState.votes).length;
        io.to(`session:${sessionId}`).emit(EVENTS.VOTE_CAST, {
          sessionId,
          roundNumber,
          votedCount,
        });

        // ── 자동 집계: 모든 생존자가 투표 완료 ──────────────────────────
        const gameRaw = await redisClient.get(`game:${sessionId}`);
        if (!gameRaw) return;

        const gameState = JSON.parse(gameRaw);
        if (votedCount < gameState.alivePlayerIds.length) return;

        // 득표 집계
        const tally = {};
        for (const vote of Object.values(roundState.votes)) {
          tally[vote] = (tally[vote] ?? 0) + 1;
        }

        const eliminatedUserId = Object.entries(tally).reduce(
          (top, [id, count]) => (count > (tally[top] ?? 0) ? id : top),
          Object.keys(tally)[0]
        );

        // 탈락 처리
        await redisClient.set(
          `eliminated:${sessionId}:${eliminatedUserId}`,
          '1',
          { EX: 86400 }
        );

        io.to(`session:${sessionId}`).emit(EVENTS.VOTE_RESULT, {
          sessionId,
          roundNumber,
          eliminatedUserId,
          voteBreakdown: tally,
        });

      } catch (err) {
        console.error('[WS] vote:cast error:', err);
        socket.emit(EVENTS.MODULE_ERROR, { code: 'INTERNAL_ERROR' });
      }
    });

    // ── status:update ─────────────────────────────────────────────────
    // 이동중 / 정지 / SOS 등 상태 변경
    socket.on(EVENTS.STATUS_UPDATE, async ({ sessionId: sid, status, battery }) => {
      const sessionId = sid || socket.currentSessionId;
      if (!sessionId) return;

      const validStatuses = ['moving', 'stopped', 'sos', 'idle'];
      if (!validStatuses.includes(status)) return;

      const payload = {
        userId,
        nickname: socket.user.nickname,
        status,
        battery,
        timestamp: Date.now(),
      };

      io.to(`session:${sessionId}`).emit(EVENTS.STATUS_CHANGED, payload);
    });

    // ── sos:trigger ───────────────────────────────────────────────────
    // 긴급 SOS 발송 → 세션 전체에 고우선순위 알림
    socket.on(EVENTS.SOS_TRIGGER, async ({ sessionId: sid, message, lat, lng }) => {
      const sessionId = sid || socket.currentSessionId;
      if (!sessionId) return;

      console.warn(`[SOS] User ${userId} triggered SOS in session ${sessionId}`);

      const sosPayload = {
        userId,
        nickname: socket.user.nickname,
        message: message || '긴급 상황 발생!',
        location: lat && lng ? { lat, lng } : null,
        timestamp: Date.now(),
      };

      // 세션 전체에 SOS 브로드캐스트 (본인 포함)
      io.to(`session:${sessionId}`).emit(EVENTS.SOS_ALERT, sosPayload);

      // FCM 고우선순위 푸시: 백그라운드 멤버에게도 전달
      sendSosAlert({
        sessionId,
        triggeredByUserId: userId,
        nickname: socket.user.nickname,
        location: lat && lng ? { lat, lng } : null,
        sosMessage: message || '긴급 상황 발생!',
      }).catch((err) => console.error('[WS] FCM SOS error:', err));
    });

    // ── disconnect ────────────────────────────────────────────────────
    socket.on('disconnect', (reason) => {
      console.log(`[WS] Disconnected: ${socket.user.nickname} - ${reason}`);

      const sessionId = socket.currentSessionId;
      if (sessionId) {
        socket.to(`session:${sessionId}`).emit(EVENTS.MEMBER_LEFT, {
          userId,
          nickname: socket.user.nickname,
          reason,
          timestamp: Date.now(),
        });
      }
    });
  });

  return io;
};
