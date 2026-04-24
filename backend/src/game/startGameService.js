import { redisClient } from '../config/redis.js';
import * as sessionService from '../services/sessionService.js';
import * as MissionSystem from './MissionSystem.js';
import * as AIDirector from '../ai/AIDirector.js';
import { getMediaServer } from '../media/MediaServer.js';
import { GamePluginRegistry } from './index.js';
import { keys } from '../websocket/socketRuntime.js';
import { validateFantasyWarsStart } from './plugins/fantasy_wars_artifact/startValidation.js';

const GAME_TTL = 86400;

const GAME_EVENTS = {
  started:      'game:started',
  roleAssigned: 'game:role_assigned',
  aiMessage:    'game:ai_message',
};

async function emitGameStartAnnouncement({ io, sessionId, session, gameState, aliveMembers }) {
  try {
    const ps = gameState.pluginState ?? {};
    const gameType = session.game_type ?? 'among_us';
    let msg;

    if (gameType === 'fantasy_wars_artifact') {
      const roomLike = {
        roomId: sessionId,
        pluginState: ps,
        alivePlayerIds: aliveMembers.map((member) => member.user_id),
      };
      msg = await AIDirector.fwOnGameStart(roomLike);
    } else {
      const impostors = Array.isArray(ps.impostors) ? ps.impostors : [];
      const roomLike = {
        players: new Map(
          aliveMembers.map((member) => [member.user_id, {
            userId: member.user_id,
            nickname: member.nickname ?? member.user_id,
            team: impostors.includes(member.user_id) ? 'impostor' : 'crew',
          }]),
        ),
        impostors,
      };
      msg = await AIDirector.onGameStart(roomLike);
    }

    if (msg) {
      io.to(`session:${sessionId}`).emit(GAME_EVENTS.aiMessage, {
        type: 'announcement',
        message: msg,
      });
    }
  } catch (error) {
    console.error('[AI] game start announcement failed:', error.message);
  }
}

function assertFantasyWarsLayoutReady(session, config) {
  const playableArea = Array.isArray(session?.playable_area) ? session.playable_area : [];
  const controlPoints = Array.isArray(config?.controlPoints) ? config.controlPoints : [];
  const spawnZones = Array.isArray(config?.spawnZones) ? config.spawnZones : [];
  const expectedControlPoints = Number(config?.controlPointCount ?? 5);
  const expectedSpawnZones = Number(config?.teamCount ?? 3);

  if (playableArea.length < 3) {
    throw new Error('FANTASY_WARS_PLAYABLE_AREA_REQUIRED');
  }
  if (controlPoints.length !== expectedControlPoints) {
    throw new Error('FANTASY_WARS_CONTROL_POINTS_REQUIRED');
  }
  if (spawnZones.length !== expectedSpawnZones) {
    throw new Error('FANTASY_WARS_SPAWN_ZONES_REQUIRED');
  }
}

export const startGameForSession = async ({ io, sessionId, requesterUserId }) => {
  // ── 권한 & 세션 검증 ──────────────────────────────────────────────────────
  const session = await sessionService.getSession(sessionId);
  if (!session) throw new Error('SESSION_NOT_FOUND');
  if (session.host_user_id !== requesterUserId) throw new Error('NOT_HOST');

  // ── 중복 시작 방지: 이미 진행 중인 게임이 있으면 차단 ─────────────────────
  const alreadyStarted = await redisClient.get(keys.started(sessionId));
  if (alreadyStarted) throw new Error('GAME_ALREADY_STARTED');

  const members = await sessionService.getSessionMembers(sessionId);
  const aliveMembers = members.filter(m => m?.user_id);

  if (aliveMembers.length < 2) {
    const err = new Error('NOT_ENOUGH_PLAYERS');
    err.details = { required: 2, current: aliveMembers.length };
    throw err;
  }

  // ── plugin 선택 ───────────────────────────────────────────────────────────
  const gameType = session.game_type ?? 'among_us';
  const plugin   = GamePluginRegistry.get(gameType);

  // plugin config: game_config JSONB 우선, 세션 컬럼 폴백
  const config = {
    ...(plugin.defaultConfig ?? {}),
    ...(session.game_config ?? {}),
    // 레거시 컬럼 폴백
    impostorCount:  session.impostor_count  ?? plugin.defaultConfig?.impostorCount  ?? 1,
    kill_cooldown:  session.kill_cooldown   ?? plugin.defaultConfig?.killCooldown   ?? 30,
    discussion_time: session.discussion_time ?? plugin.defaultConfig?.discussionTime ?? 90,
    vote_time:       session.vote_time       ?? plugin.defaultConfig?.voteTime       ?? 30,
    mission_per_crew: session.mission_per_crew ?? plugin.defaultConfig?.missionPerCrew ?? 3,
  };

  if (gameType === 'fantasy_wars_artifact') {
    assertFantasyWarsLayoutReady(session, config);
    validateFantasyWarsStart(aliveMembers, config);
  }

  // ── plugin.startSession ───────────────────────────────────────────────────
  const { gameState, roles } = await plugin.startSession({
    session,
    members: aliveMembers,
    config,
    io,
  });

  // ── Redis 저장 (새 key namespace) ─────────────────────────────────────────
  await Promise.all([
    redisClient.set(keys.state(sessionId),   JSON.stringify(gameState), { EX: GAME_TTL }),
    redisClient.set(keys.started(sessionId), '1',                       { EX: GAME_TTL }),
  ]);

  // ── 공통 payload ──────────────────────────────────────────────────────────
  const startedPayload = {
    sessionId,
    gameType,
    playerCount:   aliveMembers.length,
    startedAt:     new Date(gameState.startedAt).toISOString(),
    activeModules: Array.isArray(session.active_modules) ? session.active_modules : [],
    ...(plugin.getPublicState?.(gameState) ?? {}),
  };

  // ── media ─────────────────────────────────────────────────────────────────
  const mediaRoom = getMediaServer()?.getRoom(sessionId);
  if (mediaRoom) {
    mediaRoom.setAlivePeers(aliveMembers.map(m => m.user_id));
    mediaRoom.muteAll();
  }

  // ── 브로드캐스트: 게임 시작 ───────────────────────────────────────────────
  io.to(`session:${sessionId}`).emit(GAME_EVENTS.started, startedPayload);

  // ── 개인 역할 배정 ────────────────────────────────────────────────────────
  for (const roleAssignment of roles) {
    io.to(`user:${roleAssignment.userId}`).emit(GAME_EVENTS.roleAssigned, {
      role: roleAssignment.role,
      team: roleAssignment.team,
      ...(roleAssignment.privateData ?? {}),
    });
  }

  // ── 미션 배정 ─────────────────────────────────────────────────────────────
  if (gameType === 'among_us') {
    try {
      await MissionSystem.assignMissions(session, aliveMembers);
      for (const member of aliveMembers) {
        const missions = await MissionSystem.getMissions(sessionId, member.user_id);
        if (missions?.length > 0) {
          io.to(`user:${member.user_id}`).emit('game:missions_assigned', { missions });
        }
      }
    } catch (e) {
      console.error('[Mission] 미션 배정 실패 (게임은 계속):', e.message);
    }
  }

  // ── AI 시작 알림 ──────────────────────────────────────────────────────────
  void emitGameStartAnnouncement({
    io,
    sessionId,
    session,
    gameState,
    aliveMembers,
  });

  return { session, aliveMembers, gameState, startedPayload };
};
