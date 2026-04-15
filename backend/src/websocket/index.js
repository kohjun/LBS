// src/websocket/index.js
import { Server } from 'socket.io';
import { createAdapter } from '@socket.io/redis-streams-adapter'; // ★ 4. Redis Streams Adapter 추가
import { verifySocketToken } from '../middleware/auth.js';
import { redisClient } from '../config/redis.js';
import * as locationService from '../services/locationService.js';
import * as sessionService from '../services/sessionService.js';
import { sendSosAlert, sendGeofenceAlert } from '../services/fcmService.js';
import { checkGeofences } from '../services/geofenceService.js';
import VoteSystem, { VOTE_PHASE } from '../game/VoteSystem.js';
import * as MissionSystem from '../game/MissionSystem.js';
import KillCooldownManager from '../game/KillCooldownManager.js';
import EventBus from '../game/EventBus.js';
import * as AIDirector from '../ai/AIDirector.js';
import { startGameForSession } from '../game/startGameService.js';
import { getMediaServer } from '../media/MediaServer.js';
import { registerMediaSignalingHandlers } from './mediaSignaling.js';

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
  MEDIA_GET_ROUTER_RTP_CAPABILITIES: 'getRouterRtpCapabilities',
  MEDIA_GET_PRODUCERS:                 'getProducers',
  MEDIA_CREATE_WEBRTC_TRANSPORT:     'createWebRtcTransport',
  MEDIA_CONNECT_WEBRTC_TRANSPORT:    'connectWebRtcTransport',
  MEDIA_PRODUCE:                     'produce',
  MEDIA_CONSUME:                     'consume',

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
  MEDIA_NEW_PRODUCER:   'media:newProducer',
  MEDIA_PRODUCER_CLOSED:'media:producerClosed',
  VOICE_SPEAKING:     'voice:speaking',
  ERROR:              'error',

  // Amongus Client → Server
  GAME_KILL:          'game:kill',
  GAME_REPORT:        'game:report',
  GAME_EMERGENCY:     'game:emergency',
  GAME_VOTE:          'game:vote',
  GAME_MISSION_DONE:  'game:mission_complete',
  GAME_AI_ASK:        'game:ai_ask',

  // Amongus Server → Client
  GAME_STARTED:            'game:started',
  GAME_ROLE_ASSIGNED:      'game:role_assigned',
  GAME_KILL_CONFIRMED:     'game:kill_confirmed',
  GAME_BODY_FOUND:         'game:body_found',
  GAME_MEETING_STARTED:    'game:meeting_started',
  GAME_MEETING_TICK:       'game:meeting_tick',
  GAME_VOTING_STARTED:     'game:voting_started',
  GAME_VOTE_SUBMITTED:     'game:vote_submitted',
  GAME_PRE_VOTE_SUBMITTED: 'game:pre_vote_submitted',
  GAME_VOTE_RESULT:        'game:vote_result',
  GAME_MEETING_ENDED:      'game:meeting_ended',
  GAME_AI_MESSAGE:         'game:ai_message',
  GAME_AI_REPLY:           'game:ai_reply',
  GAME_MISSION_PROGRESS:   'game:mission_progress',
  TASK_PROGRESS:           'task_progress',
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

const normalizeGameState = (rawGameState = {}) => {
  const alivePlayerIds = Array.isArray(rawGameState.alivePlayerIds)
    ? rawGameState.alivePlayerIds
    : Array.isArray(rawGameState.aliveMembers)
      ? rawGameState.aliveMembers
      : [];

  return {
    status: rawGameState.status === 'playing'
      ? 'in_progress'
      : (rawGameState.status ?? 'in_progress'),
    startedAt: rawGameState.startedAt ?? Date.now(),
    finishedAt: rawGameState.finishedAt ?? null,
    impostors: Array.isArray(rawGameState.impostors) ? rawGameState.impostors : [],
    alivePlayerIds,
    killLog: Array.isArray(rawGameState.killLog) ? rawGameState.killLog : [],
    meetingCount: Number.isInteger(rawGameState.meetingCount) ? rawGameState.meetingCount : 0,
  };
};

const saveGameState = async (sessionId, rawGameState, ttlSeconds = 86400) => {
  const normalized = normalizeGameState(rawGameState);
  await redisClient.set(`game:${sessionId}`, JSON.stringify(normalized), { EX: ttlSeconds });
  return normalized;
};

// ─────────────────────────────────────────────────────────────────────────────
// io 인스턴스 참조
// ─────────────────────────────────────────────────────────────────────────────
let _io = null;
export const getIo = () => _io;

const syncMediaRoomState = async (sessionId, room) => {
  if (!room) {
    return null;
  }

  const gameRaw = await redisClient.get(`game:${sessionId}`);
  if (!gameRaw) {
    room.setAlivePeers([...room.peers.keys()]);
    room.openLobbyVoice();
    return null;
  }

  const gameState = normalizeGameState(JSON.parse(gameRaw));
  room.setAlivePeers(gameState.alivePlayerIds);

  if (VoteSystem.hasActiveMeeting(sessionId)) {
    room.startEmergencyMeeting();
  } else if (gameState.status === 'in_progress') {
    room.muteAll();
  } else {
    room.openLobbyVoice();
  }

  return gameState;
};

const ensureMediaRoomForSocket = async ({ socket, mediaServer, sessionId }) => {
  if (!mediaServer) {
    return null;
  }

  const room = await mediaServer.getOrCreateRoom(sessionId);
  room.addPeer({
    userId: socket.user.id,
    socket,
    isAlive: true,
  });

  await syncMediaRoomState(sessionId, room);
  return room;
};

// ─────────────────────────────────────────────────────────────────────────────
// Socket.IO 서버 초기화
// ─────────────────────────────────────────────────────────────────────────────
export const createSocketServer = (
  httpServer,
  { mediaServer = getMediaServer() } = {},
) => {
  _io = new Server(httpServer, {
    cors: {
      origin: process.env.ALLOWED_ORIGINS?.split(',') || '*',
      credentials: true,
    },
    pingTimeout: 60000,
    pingInterval: 25000,
    transports: ['websocket', 'polling'],
  });
  const io = _io; 

  // ★ 4. Redis Streams Adapter 장착 (OOM 방지를 위한 maxLen 10000 설정)
  io.adapter(createAdapter(redisClient, { maxLen: 10000 }));

  // ── 전역 인증 미들웨어 ─────────────────────────────────────────────────
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

    socket.join(`user:${userId}`);

    const leaveSession = async (sessionIdToLeave = socket.currentSessionId) => {
      if (!sessionIdToLeave) {
        return;
      }

      socket.leave(`session:${sessionIdToLeave}`);
      mediaServer?.removePeer(sessionIdToLeave, userId);

      if (socket.currentSessionId === sessionIdToLeave) {
        socket.currentSessionId = null;
      }
    };

    if (mediaServer) {
      registerMediaSignalingHandlers({
        socket,
        mediaServer,
        events: EVENTS,
        syncRoomState: syncMediaRoomState,
      });
    }

    // ── session:join ──────────────────────────────────────────────────
    socket.on(EVENTS.JOIN_SESSION, async ({ sessionId }) => {
      if (!sessionId) {
        return socket.emit(EVENTS.ERROR, { code: 'MISSING_SESSION_ID' });
      }

      try {
        const members = await sessionService.getSessionMembers(sessionId);
        const isMember = members.some((m) => m.user_id === userId);
        if (!isMember) {
          return socket.emit(EVENTS.ERROR, { code: 'NOT_A_MEMBER' });
        }

        if (socket.currentSessionId && socket.currentSessionId !== sessionId) {
          await leaveSession(socket.currentSessionId);
        }

        const roomName = `session:${sessionId}`;
        socket.join(roomName);
        socket.currentSessionId = sessionId;

        const memberIds = members.map((m) => m.user_id);
        const snapshot = await locationService.getSessionSnapshot(sessionId, memberIds);

        socket.emit(EVENTS.SESSION_SNAPSHOT, {
          sessionId,
          members,
          locations: snapshot,
        });

        socket.to(roomName).emit(EVENTS.MEMBER_JOINED, {
          userId,
          nickname: socket.user.nickname,
          timestamp: Date.now(),
        });

        socket.emit(EVENTS.SESSION_JOINED, { sessionId, memberCount: members.length });

        await ensureMediaRoomForSocket({
          socket,
          mediaServer,
          sessionId,
        });

      } catch (err) {
        console.error('[WS] join error:', err);
        socket.emit(EVENTS.ERROR, { code: 'JOIN_FAILED' });
      }
    });

    // ── location:update ───────────────────────────────────────────────
    socket.on(EVENTS.LEAVE_SESSION, async ({ sessionId: sid } = {}) => {
      const sessionId = sid || socket.currentSessionId;
      if (!sessionId) return;

      await leaveSession(sessionId);

      socket.to(`session:${sessionId}`).emit(EVENTS.MEMBER_LEFT, {
        userId,
        nickname: socket.user.nickname,
        reason: 'leave',
        timestamp: Date.now(),
      });
    });

    socket.on(EVENTS.LOCATION_UPDATE, async (payload) => {
      const sessionId = socket.currentSessionId || payload.sessionId;
      if (!sessionId) return;

      const { lat, lng, accuracy, altitude, speed, heading, source, battery, status } = payload;

      if (typeof lat !== 'number' || typeof lng !== 'number') return;
      if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return;

      try {
        const saved = await locationService.saveLocation(userId, sessionId, {
          lat, lng, accuracy, altitude, speed, heading,
          source: source || 'gps',
          battery,
          status: status || 'moving',
        });

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

        // Realtime 브로드캐스트
        socket.to(`session:${sessionId}`).emit(EVENTS.LOCATION_CHANGED, broadcastData);

        // ★ 2. 지오펜스 DB 과부하 방지 (5초 쓰로틀링)
        const geoThrottleKey = `throttle:geo:${sessionId}:${userId}`;
        const canCheckGeo = await redisClient.set(geoThrottleKey, '1', { NX: true, EX: 5 });
        
        if (canCheckGeo) {
          checkGeofences(userId, sessionId, lat, lng)
            .then(({ entered, exited }) => {
              if (entered.length > 0) {
                sendGeofenceAlert({
                  sessionId, userId,
                  nickname: socket.user.nickname,
                  geofences: entered,
                  eventType: 'enter',
                }).catch((e) => console.error('[WS] FCM geofence enter error:', e));
              }
              if (exited.length > 0) {
                sendGeofenceAlert({
                  sessionId, userId,
                  nickname: socket.user.nickname,
                  geofences: exited,
                  eventType: 'exit',
                }).catch((e) => console.error('[WS] FCM geofence exit error:', e));
              }
            })
            .catch((e) => console.error('[WS] checkGeofences error:', e));
        }

      } catch (err) {
        console.error('[WS] location update error:', err);
      }
    });

    // ── action:interact (PROXIMITY_KILL) ───────────────────────────────
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

          // ★ 1. 동시 타격(Kill) 방어 락: '타겟(피해자)' 기준으로 2초간 락 설정
          const lockKey = `target_lock:${sessionId}:${targetUserId}`;
          const locked = await redisClient.set(lockKey, '1', { NX: true, EX: 2 });
          if (!locked) return; // 이미 다른 사람에게 처리 중 (중복 무시)

          // ── Tag 모듈 활성 시: 킬 대신 태그 전달 ────────────────────────
          if (activeModules.includes('tag')) {
            await redisClient.set(`tag:${sessionId}:tagger`, userId, { EX: 86400 });

            socket.emit(EVENTS.ACTION_RESULT, {
              actionType, sessionId, targetUserId, status: 'success',
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
          await redisClient.set(`eliminated:${sessionId}:${targetUserId}`, '1', { EX: 86400 });

          socket.emit(EVENTS.ACTION_RESULT, {
            actionType, sessionId, targetUserId, status: 'success',
          });

          io.to(`user:${targetUserId}`).emit('proximity:killed', {
            killedBy: userId,
            nickname: socket.user.nickname,
            sessionId,
          });

          io.to(`session:${sessionId}`).emit(EVENTS.PLAYER_ELIMINATED, {
            userId:    targetUserId,
            killedBy:  userId,
            nickname:  socket.user.nickname,
            sessionId,
            timestamp: Date.now(),
          });

          const gameRaw = await redisClient.get(`game:${sessionId}`);
          if (gameRaw) {
            const gameState = normalizeGameState(JSON.parse(gameRaw));
            if (gameState.status === 'in_progress') {
              gameState.alivePlayerIds = gameState.alivePlayerIds.filter(
                (id) => id !== targetUserId
              );

              mediaServer?.getRoom(sessionId)?.setAlivePeers(gameState.alivePlayerIds);

              if (gameState.alivePlayerIds.length === 1) {
                gameState.status = 'finished';
                gameState.finishedAt = Date.now();
                await saveGameState(sessionId, gameState);
                io.to(`session:${sessionId}`).emit(EVENTS.GAME_OVER, {
                  winnerId:  gameState.alivePlayerIds[0],
                  sessionId,
                  timestamp: Date.now(),
                });
              } else {
                await saveGameState(sessionId, gameState);
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
    socket.on(EVENTS.GAME_START, async ({ sessionId: sid } = {}) => {
      const sessionId = sid || socket.currentSessionId;
      if (!sessionId) return;
      try {
        await startGameForSession({ io, sessionId, requesterUserId: userId });
      } catch (err) {
        console.error('[WS] game:start error:', err);
        socket.emit(EVENTS.ERROR, {
          code: err.message || 'GAME_START_FAILED',
          ...(err.details ?? {}),
        });
      }
    });

    // ── game:kill (어몽어스 킬) ─────────────────────────────────────────
    socket.on(EVENTS.GAME_KILL, async ({ sessionId: sid, targetUserId }) => {
      const sessionId = sid || socket.currentSessionId;
      if (!sessionId || !targetUserId) return;
      try {
        const gameRaw = await redisClient.get(`game:${sessionId}`);
        if (!gameRaw) {
          return socket.emit(EVENTS.ERROR, { code: 'GAME_NOT_STARTED' });
        }
        const gameState = normalizeGameState(JSON.parse(gameRaw));

        if (!gameState.impostors.includes(userId)) return;
        if (!gameState.alivePlayerIds.includes(targetUserId)) return;
        if (!KillCooldownManager.canKill(sessionId, userId)) {
          return socket.emit(EVENTS.ERROR, { code: 'KILL_COOLDOWN' });
        }

        // ★ 1. 동시 타격(Kill) 방어 락: '타겟' 기준으로 2초간 락 (어몽어스 모드)
        const lockKey = `target_lock:${sessionId}:${targetUserId}`;
        const locked = await redisClient.set(lockKey, '1', { NX: true, EX: 2 });
        if (!locked) return; // 이미 죽은 처리 중

        gameState.alivePlayerIds = gameState.alivePlayerIds.filter((id) => id !== targetUserId);
        gameState.killLog.push({ killerId: userId, victimId: targetUserId, at: Date.now() });
        mediaServer?.getRoom(sessionId)?.setAlivePeers(gameState.alivePlayerIds);
        await saveGameState(sessionId, gameState);

        KillCooldownManager.setKillCooldown(sessionId, userId, 30);

        io.to(`session:${sessionId}`).emit(EVENTS.GAME_KILL_CONFIRMED, {
          victimId: targetUserId,
        });
        socket.emit(EVENTS.GAME_KILL_CONFIRMED, { ok: true });

        try {
          const members = await sessionService.getSessionMembers(sessionId);
          const memberById = new Map(
            members.map((member) => [member.user_id, member]),
          );
          const killer = memberById.get(userId) ?? {
            user_id: userId,
            nickname: socket.user.nickname ?? userId,
          };
          const target = memberById.get(targetUserId) ?? {
            user_id: targetUserId,
            nickname: targetUserId,
          };
          const msg = await AIDirector.onKill(
            {
              roomId: sessionId,
              killLog: gameState.killLog,
              alivePlayerIds: gameState.alivePlayerIds,
              impostors: gameState.impostors,
            },
            {
              userId,
              nickname: killer.nickname ?? userId,
            },
            {
              userId: targetUserId,
              nickname: target.nickname ?? targetUserId,
              zone: target.zone ?? '',
            },
          );
          if (msg) {
            io.to(`session:${sessionId}`).emit(EVENTS.GAME_AI_MESSAGE, {
              type: 'kill',
              message: msg,
            });
          }
        } catch (aiError) {
          console.error('[AI] kill announcement failed:', aiError.message);
        }

        const aliveImpostors = gameState.impostors.filter((id) => gameState.alivePlayerIds.includes(id));
        const aliveCrew = gameState.alivePlayerIds.filter((id) => !gameState.impostors.includes(id));
        
        if (aliveImpostors.length === 0) {
          io.to(`session:${sessionId}`).emit(EVENTS.GAME_OVER, { winner: 'crew', reason: 'impostors_ejected' });
        } else if (aliveImpostors.length >= aliveCrew.length) {
          io.to(`session:${sessionId}`).emit(EVENTS.GAME_OVER, { winner: 'impostor' });
        }
      } catch (err) {
        console.error('[WS] game:kill error:', err);
      }
    });

    // ── game:emergency ────────────────────────────────────────────────
    socket.on(EVENTS.GAME_EMERGENCY, async ({ sessionId: sid } = {}, cb) => {
      const sessionId = sid || socket.currentSessionId;
      const respond = typeof cb === 'function' ? cb : () => {};
      if (!sessionId) return respond({ ok: false, error: 'MISSING_SESSION_ID' });
      try {
        const gameRaw = await redisClient.get(`game:${sessionId}`);
        if (!gameRaw) return respond({ ok: false, error: 'GAME_NOT_STARTED' });
        const gameState = normalizeGameState(JSON.parse(gameRaw));
        if (!gameState.alivePlayerIds.includes(userId)) {
          return respond({ ok: false, error: 'ONLY_ALIVE_PLAYERS' });
        }

        const [session, members] = await Promise.all([
          sessionService.getSession(sessionId),
          sessionService.getSessionMembers(sessionId),
        ]);
        if (!session) return respond({ ok: false, error: 'SESSION_NOT_FOUND' });
        
        session.aliveMembers = members.filter((member) =>
          gameState.alivePlayerIds.includes(member.user_id),
        );

        VoteSystem.startMeeting(session, { callerId: userId, bodyId: null, reason: 'emergency' });
        respond({ ok: true });
      } catch (err) {
        console.error('[WS] game:emergency error:', err);
        respond({ ok: false, error: err.message });
      }
    });

    // ── game:report ───────────────────────────────────────────────────
    socket.on(EVENTS.GAME_REPORT, async ({ sessionId: sid, bodyId }, cb) => {
      const sessionId = sid || socket.currentSessionId;
      const respond = typeof cb === 'function' ? cb : () => {};
      if (!sessionId || !bodyId) return respond({ ok: false, error: 'MISSING_FIELDS' });
      try {
        const gameRaw = await redisClient.get(`game:${sessionId}`);
        if (!gameRaw) return respond({ ok: false, error: 'GAME_NOT_STARTED' });
        const gameState = normalizeGameState(JSON.parse(gameRaw));
        
        if (!gameState.alivePlayerIds.includes(userId)) return respond({ ok: false, error: 'ONLY_ALIVE_PLAYERS' });
        if (gameState.alivePlayerIds.includes(bodyId)) return respond({ ok: false, error: 'BODY_NOT_FOUND' });

        const [session, members] = await Promise.all([
          sessionService.getSession(sessionId),
          sessionService.getSessionMembers(sessionId),
        ]);
        if (!session) return respond({ ok: false, error: 'SESSION_NOT_FOUND' });
        
        session.aliveMembers = members.filter((member) =>
          gameState.alivePlayerIds.includes(member.user_id),
        );

        VoteSystem.startMeeting(session, { callerId: userId, bodyId, reason: 'report' });
        respond({ ok: true });
      } catch (err) {
        console.error('[WS] game:report error:', err);
        respond({ ok: false, error: err.message });
      }
    });

    // ── game:vote ─────────────────────────────────────────────────────
    socket.on(EVENTS.GAME_VOTE, ({ sessionId: sid, targetId }, cb) => {
      const sessionId = sid || socket.currentSessionId;
      const respond = typeof cb === 'function' ? cb : () => {};
      if (!sessionId || !targetId) return respond({ ok: false, error: 'MISSING_FIELDS' });
      try {
        const result = VoteSystem.submitVote(sessionId, userId, targetId);
        respond({ ok: true, ...result });
      } catch (err) {
        respond({ ok: false, error: err.message });
      }
    });

    // ── game:mission_complete ─────────────────────────────────────────
    socket.on(EVENTS.GAME_MISSION_DONE, async ({ sessionId: sid, missionId }) => {
      const sessionId = sid || socket.currentSessionId;
      if (!sessionId || !missionId) return;
      try {
        const result = await MissionSystem.completeMission(sessionId, userId, missionId);
        if (!result) return;

        const progressData = await MissionSystem.getProgressBar(sessionId);
        socket.emit(EVENTS.GAME_MISSION_PROGRESS, { missionId, ...progressData });
        io.to(`session:${sessionId}`).emit(EVENTS.GAME_MISSION_PROGRESS, progressData);

        // task_progress: 0.0 ~ 1.0 진행도를 방 전체에 브로드캐스트
        const taskProgressValue = progressData.total > 0
          ? progressData.completed / progressData.total
          : 0;
        io.to(`session:${sessionId}`).emit(EVENTS.TASK_PROGRESS, {
          progress: taskProgressValue,
          completed: progressData.completed,
          total: progressData.total,
          percent: progressData.percent,
        });

        if (result.allDone) {
          io.to(`session:${sessionId}`).emit(EVENTS.GAME_OVER, { winner: 'crew', reason: 'all_missions_done' });
        }
      } catch (err) {
        console.error('[WS] game:mission_complete error:', err);
      }
    });

    // ── game:ai_ask ───────────────────────────────────────────────────
    socket.on(EVENTS.GAME_AI_ASK, async ({ sessionId: sid, question }, cb) => {
      const sessionId = sid || socket.currentSessionId;
      const respond = typeof cb === 'function' ? cb : () => {};

      if (!question || question.trim().length === 0) {
        return respond({ ok: false, error: '질문을 입력해주세요.' });
      }
      if (question.length > 200) {
        return respond({ ok: false, error: '질문이 너무 깁니다. (최대 200자)' });
      }

      // ★ 3. AI 쿨타임 쓰로틀링 (도배 방지 및 API 요금 최적화: 5초)
      const aiLimitKey = `throttle:ai:${sessionId}:${userId}`;
      const canAsk = await redisClient.set(aiLimitKey, '1', { NX: true, EX: 5 });
      if (!canAsk) {
        return respond({ ok: false, error: 'AI 마스터가 답변을 준비 중입니다. 잠시 후 다시 질문해주세요.' });
      }

      try {
        const gameRaw = await redisClient.get(`game:${sessionId}`);
        if (!gameRaw) return respond({ ok: false, error: '게임이 시작되지 않았습니다.' });

        const gameState  = normalizeGameState(JSON.parse(gameRaw));
        const isImpostor = gameState.impostors.includes(userId);

        const roomLike = {
          roomId:         sessionId,
          gameType:       'among_us',
          status:         gameState.status,
          killLog:        gameState.killLog || [],
          alivePlayerIds: gameState.alivePlayerIds || [],
          players:        new Map(
            (gameState.alivePlayerIds || []).map((id) => [id, {
              userId: id,
              isAlive: true,
              team: gameState.impostors.includes(id) ? 'impostor' : 'crew',
            }])
          ),
        };

        const playerLike = {
          userId,
          nickname:  socket.user.nickname,
          team:      isImpostor ? 'impostor' : 'crew',
          roleId:    isImpostor ? 'impostor' : 'crew',
          isAlive:   gameState.alivePlayerIds.includes(userId),
          tasks:     [],
        };

        respond({ ok: true });

        const {
          answer,
          sources,
          isError = false,
          errorCode = null,
        } = await AIDirector.ask(roomLike, playerLike, question);

        socket.emit(EVENTS.GAME_AI_REPLY, { question, answer, sources, isError, errorCode });

      } catch (err) {
        console.error('[WS] game:ai_ask error:', err);
        socket.emit(EVENTS.GAME_AI_REPLY, {
          question,
          answer: '죄송해요, 잠시 후 다시 물어봐주세요! 🙏',
          sources: [],
          isError: true,
          errorCode: 'AI_UNAVAILABLE',
        });
      }
    });

    // ── voice:speaking ────────────────────────────────────────────────
    socket.on(EVENTS.VOICE_SPEAKING, ({ sessionId: sid, isSpeaking }) => {
      const sessionId = sid || socket.currentSessionId;
      if (!sessionId) return;
      socket.to(`session:${sessionId}`).emit(EVENTS.VOICE_SPEAKING, {
        userId,
        isSpeaking: !!isSpeaking,
      });
    });

    // ── game:request_state ────────────────────────────────────────────
    socket.on(EVENTS.GAME_REQUEST_STATE, async ({ sessionId: sid } = {}) => {
      const sessionId = sid || socket.currentSessionId;
      if (!sessionId) return;

      try {
        const gameRaw = await redisClient.get(`game:${sessionId}`);
        if (!gameRaw) {
          return socket.emit(EVENTS.GAME_STATE_UPDATE, { sessionId, status: 'none' });
        }

        const [gameState, taggerId] = await Promise.all([
          Promise.resolve(normalizeGameState(JSON.parse(gameRaw))),
          redisClient.get(`tag:${sessionId}:tagger`),
        ]);
        const isImpostor = gameState.impostors.includes(userId);

        socket.emit(EVENTS.GAME_STATE_UPDATE, {
          sessionId,
          status:         gameState.status,
          startedAt:      gameState.startedAt,
          finishedAt:     gameState.finishedAt,
          aliveCount:     gameState.alivePlayerIds.length,
          alivePlayerIds: gameState.alivePlayerIds,
          taggerId:       taggerId ?? null,
          role:           isImpostor ? 'impostor' : 'crew',
          team:           isImpostor ? 'impostor' : 'crew',
          impostors:      isImpostor ? gameState.impostors : [],
        });
      } catch (err) {
        console.error('[WS] game:request_state error:', err);
      }
    });

    // ── round:start / vote:open / vote:cast 등 기존 로직 생략 없이 유지 ───
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

        const roundState = { roundNumber, phase: 'discussing', startedAt: Date.now(), votes: {} };
        await redisClient.set(`round:${sessionId}:${roundNumber}`, JSON.stringify(roundState), { EX: 86400 });

        io.to(`session:${sessionId}`).emit(EVENTS.ROUND_START, { sessionId, ...roundState });
      } catch (err) {
        console.error('[WS] round:start error:', err);
        socket.emit(EVENTS.MODULE_ERROR, { code: 'INTERNAL_ERROR' });
      }
    });

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
        await redisClient.set(`round:${sessionId}:${roundNumber}`, JSON.stringify(roundState), { EX: 86400 });

        io.to(`session:${sessionId}`).emit(EVENTS.VOTE_OPEN, { sessionId, roundNumber, prompt: prompt ?? '' });
      } catch (err) {
        console.error('[WS] vote:open error:', err);
        socket.emit(EVENTS.MODULE_ERROR, { code: 'INTERNAL_ERROR' });
      }
    });

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
        await redisClient.set(`round:${sessionId}:${roundNumber}`, JSON.stringify(roundState), { EX: 86400 });

        const votedCount = Object.keys(roundState.votes).length;
        io.to(`session:${sessionId}`).emit(EVENTS.VOTE_CAST, { sessionId, roundNumber, votedCount });

        const gameRaw = await redisClient.get(`game:${sessionId}`);
        if (!gameRaw) return;

        const gameState = normalizeGameState(JSON.parse(gameRaw));
        if (votedCount < gameState.alivePlayerIds.length) return;

        const tally = {};
        for (const vote of Object.values(roundState.votes)) {
          tally[vote] = (tally[vote] ?? 0) + 1;
        }

        const eliminatedUserId = Object.entries(tally).reduce(
          (top, [id, count]) => (count > (tally[top] ?? 0) ? id : top),
          Object.keys(tally)[0]
        );

        await redisClient.set(`eliminated:${sessionId}:${eliminatedUserId}`, '1', { EX: 86400 });

        gameState.alivePlayerIds = gameState.alivePlayerIds.filter((id) => id !== eliminatedUserId);
        if (gameState.alivePlayerIds.length <= 1) {
          gameState.status = 'finished';
          gameState.finishedAt = Date.now();
        }
        await saveGameState(sessionId, gameState);

        io.to(`session:${sessionId}`).emit(EVENTS.VOTE_RESULT, {
          sessionId, roundNumber, eliminatedUserId, voteBreakdown: tally,
        });

        io.to(`session:${sessionId}`).emit(EVENTS.GAME_STATE_UPDATE, {
          sessionId, status: gameState.status,
          aliveCount: gameState.alivePlayerIds.length,
          alivePlayerIds: gameState.alivePlayerIds,
        });

      } catch (err) {
        console.error('[WS] vote:cast error:', err);
        socket.emit(EVENTS.MODULE_ERROR, { code: 'INTERNAL_ERROR' });
      }
    });

    // ── status / sos / disconnect 등 공통 기능 유지 ────────────────────
    socket.on(EVENTS.STATUS_UPDATE, async ({ sessionId: sid, status, battery }) => {
      const sessionId = sid || socket.currentSessionId;
      if (!sessionId) return;
      const validStatuses = ['moving', 'stopped', 'sos', 'idle'];
      if (!validStatuses.includes(status)) return;
      io.to(`session:${sessionId}`).emit(EVENTS.STATUS_CHANGED, {
        userId, nickname: socket.user.nickname, status, battery, timestamp: Date.now(),
      });
    });

    socket.on(EVENTS.SOS_TRIGGER, async ({ sessionId: sid, message, lat, lng }) => {
      const sessionId = sid || socket.currentSessionId;
      if (!sessionId) return;
      io.to(`session:${sessionId}`).emit(EVENTS.SOS_ALERT, {
        userId, nickname: socket.user.nickname,
        message: message || '긴급 상황 발생!',
        location: lat && lng ? { lat, lng } : null,
        timestamp: Date.now(),
      });
      sendSosAlert({
        sessionId, triggeredByUserId: userId, nickname: socket.user.nickname,
        location: lat && lng ? { lat, lng } : null, sosMessage: message || '긴급 상황 발생!',
      }).catch((err) => console.error('[WS] FCM SOS error:', err));
    });

    socket.on('disconnect', async (reason) => {
      console.log(`[WS] Disconnected: ${socket.user.nickname} - ${reason}`);
      const sessionId = socket.currentSessionId;
      if (sessionId) {
        socket.to(`session:${sessionId}`).emit(EVENTS.MEMBER_LEFT, {
          userId, nickname: socket.user.nickname, reason, timestamp: Date.now(),
        });
        await leaveSession(sessionId);
      }
    });
  });

  // ── VoteSystem EventBus 구독 (회의 로직 등) ──────────────────────────
  EventBus.on('meeting_started', async ({ session, voteSession }) => {
    io.to(`session:${session.id}`).emit(EVENTS.GAME_MEETING_STARTED, {
      callerId:       voteSession.callerId,
      bodyId:         voteSession.bodyId,
      reason:         voteSession.reason,
      discussionTime: voteSession.discussionTime,
    });

    const mediaRoom = mediaServer?.getRoom(session.id);
    if (mediaRoom) {
      mediaRoom.setAlivePeers(
        (session.aliveMembers ?? []).map((member) => member.user_id ?? member.userId),
      );
      mediaRoom.startEmergencyMeeting();
    }

    try {
      const caller = { nickname: voteSession.callerId };
      const body   = voteSession.bodyId ? { nickname: voteSession.bodyId, zone: '' } : null;
      const msg = await AIDirector.onMeeting(session, caller, voteSession.reason, body);
      if (msg) io.to(`session:${session.id}`).emit(EVENTS.GAME_AI_MESSAGE, { type: 'announcement', message: msg });
    } catch (e) {
      console.error('[AI] 회의 안내 실패:', e.message);
    }
  });

  EventBus.on('meeting_tick', ({ session, phase, remaining, earlyEnd }) => {
    io.to(`session:${session.id}`).emit(EVENTS.GAME_MEETING_TICK, { phase, remaining, earlyEnd });
  });

  EventBus.on('voting_started', ({ session, voteSession }) => {
    io.to(`session:${session.id}`).emit(EVENTS.GAME_VOTING_STARTED, { voteTime: voteSession.voteTime });
  });

  EventBus.on('pre_vote_submitted', ({ sessionId, count, totalPlayers }) => {
    io.to(`session:${sessionId}`).emit(EVENTS.GAME_PRE_VOTE_SUBMITTED, { totalPreVotes: count, totalPlayers });
  });

  EventBus.on('vote_submitted', ({ sessionId, count, totalPlayers }) => {
    io.to(`session:${sessionId}`).emit(EVENTS.GAME_VOTE_SUBMITTED, { totalVotes: count, totalPlayers });
  });

  EventBus.on('vote_result', async ({ session, result, ejected, ejectedMember }) => {
    let nextResult = { ...result };
    let ejectedPayload = ejected ? { userId: ejected, nickname: ejectedMember?.nickname ?? ejected } : null;

    try {
      const gameRaw = await redisClient.get(`game:${session.id}`);
      if (gameRaw) {
        const gameState = normalizeGameState(JSON.parse(gameRaw));
        if (ejected) {
          const wasImpostor = gameState.impostors.includes(ejected);
          nextResult = { ...nextResult, wasImpostor };
          if (gameState.alivePlayerIds.includes(ejected)) {
            gameState.alivePlayerIds = gameState.alivePlayerIds.filter((id) => id !== ejected);
          }
          const aliveImpostors = gameState.impostors.filter((id) => gameState.alivePlayerIds.includes(id));
          const aliveCrew = gameState.alivePlayerIds.filter((id) => !gameState.impostors.includes(id));

          let gameOverPayload = null;
          if (aliveImpostors.length === 0) {
            gameState.status = 'finished';
            gameState.finishedAt = Date.now();
            gameOverPayload = { winner: 'crew', reason: 'impostors_ejected' };
          } else if (aliveImpostors.length >= aliveCrew.length) {
            gameState.status = 'finished';
            gameState.finishedAt = Date.now();
            gameOverPayload = { winner: 'impostor', reason: 'outnumbered' };
          }

          await saveGameState(session.id, gameState);
          mediaServer?.getRoom(session.id)?.setAlivePeers(gameState.alivePlayerIds);
          mediaServer?.getRoom(session.id)?.startEmergencyMeeting();
          io.to(`session:${session.id}`).emit(EVENTS.GAME_STATE_UPDATE, {
            sessionId: session.id, status: gameState.status,
            aliveCount: gameState.alivePlayerIds.length, alivePlayerIds: gameState.alivePlayerIds,
          });
          if (gameOverPayload != null) io.to(`session:${session.id}`).emit(EVENTS.GAME_OVER, gameOverPayload);
        }
      }
    } catch (e) {
      console.error('[WS] vote_result sync error:', e);
    }
    
    io.to(`session:${session.id}`).emit(EVENTS.GAME_VOTE_RESULT, { ...nextResult, ejected: ejectedPayload });

    try {
      const msg = await AIDirector.onVoteResult(session, nextResult, ejectedPayload);
      if (msg) io.to(`session:${session.id}`).emit(EVENTS.GAME_AI_MESSAGE, { type: 'vote_result', message: msg });
    } catch (e) {
      console.error('[AI] 투표 결과 해설 실패:', e.message);
    }
  });

  EventBus.on('meeting_ended', ({ session }) => {
    mediaServer?.getRoom(session.id)?.muteAll();
    io.to(`session:${session.id}`).emit(EVENTS.GAME_MEETING_ENDED, { message: '게임으로 돌아갑니다.' });
  });

  return io;
};
