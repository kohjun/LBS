// src/services/sessionService.js
import { query, withTransaction } from '../config/database.js';
import { setCache, getCache, delCache, delPattern } from '../config/redis.js';
import { v4 as uuidv4 } from 'uuid';
import crypto from 'crypto';

const SESSION_CODE_LENGTH = 6;

// ─────────────────────────────────────────────────────────────────────────────
// 유니크 세션 코드 생성 (숫자 + 대문자 조합)
// ─────────────────────────────────────────────────────────────────────────────
const generateSessionCode = async () => {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // 혼동 문자 제외 (I,O,1,0)
  for (let attempt = 0; attempt < 10; attempt++) {
    let code = '';
    for (let i = 0; i < SESSION_CODE_LENGTH; i++) {
      code += chars[Math.floor(Math.random() * chars.length)];
    }
    // 중복 확인
    const { rows } = await query(
      "SELECT id FROM sessions WHERE session_code = $1 AND status = 'active'",
      [code]
    );
    if (rows.length === 0) return code;
  }
  throw new Error('SESSION_CODE_GENERATION_FAILED');
};

// ─────────────────────────────────────────────────────────────────────────────
// 세션 생성
// ─────────────────────────────────────────────────────────────────────────────
export const createSession = async (hostUserId, {
  name,
  activeModules   = [],
  gameType,
  impostorCount,
  killCooldown,
  discussionTime,
  voteTime,
  missionPerCrew,
} = {}) => {
  const code = await generateSessionCode();

  const rows = await withTransaction(async (client) => {
    // 세션 생성 (게임 설정 컬럼 포함)
    const session = await client.query(
      `INSERT INTO sessions
         (host_user_id, session_code, name, active_modules,
          game_type, impostor_count, kill_cooldown, discussion_time, vote_time, mission_per_crew)
       VALUES ($1, $2, $3, $4,
               COALESCE($5, 'among_us'), COALESCE($6, 1), COALESCE($7, 30),
               COALESCE($8, 90), COALESCE($9, 30), COALESCE($10, 3))
       RETURNING id, session_code, name, status, created_at, expires_at,
                 active_modules, module_configs,
                 game_type, impostor_count, kill_cooldown, discussion_time, vote_time, mission_per_crew`,
      [
        hostUserId, code, name || null, activeModules,
        gameType      ?? null,
        impostorCount ?? null,
        killCooldown  ?? null,
        discussionTime ?? null,
        voteTime      ?? null,
        missionPerCrew ?? null,
      ]
    );
    const sessionId = session.rows[0].id;

    // 호스트를 첫 번째 멤버로 자동 추가 (role = 'host')
    await client.query(
      `INSERT INTO session_members (session_id, user_id, role)
       VALUES ($1, $2, 'host')`,
      [sessionId, hostUserId]
    );

    return session.rows;
  });

  // Redis에 세션 정보 캐시 (24시간)
  await setCache(`session:code:${code}`, rows[0], 86400);
  await setCache(`session:${rows[0].id}`, rows[0], 86400);

  return rows[0];
};

// ─────────────────────────────────────────────────────────────────────────────
// 세션 참가 (초대 코드로)
// ─────────────────────────────────────────────────────────────────────────────
export const joinSession = async (userId, sessionCode) => {
  // 코드로 세션 조회 (캐시 우선)
  let session = await getCache(`session:code:${sessionCode.toUpperCase()}`);

  if (!session) {
    const { rows } = await query(
      `SELECT id, host_user_id, session_code, name, status, expires_at
       FROM sessions
       WHERE session_code = $1 AND status = 'active' AND expires_at > NOW()`,
      [sessionCode.toUpperCase()]
    );
    if (rows.length === 0) throw new Error('SESSION_NOT_FOUND');
    session = rows[0];
  }

  if (session.status !== 'active') throw new Error('SESSION_ENDED');
  if (new Date(session.expires_at) < new Date()) throw new Error('SESSION_EXPIRED');

  // 이미 참가 중인지 확인
  const { rows: existing } = await query(
    `SELECT id FROM session_members
     WHERE session_id = $1 AND user_id = $2 AND left_at IS NULL`,
    [session.id, userId]
  );
  if (existing.length > 0) throw new Error('ALREADY_IN_SESSION');

  // 멤버 추가
  await query(
    `INSERT INTO session_members (session_id, user_id)
     VALUES ($1, $2)
     ON CONFLICT (session_id, user_id)
     DO UPDATE SET left_at = NULL, joined_at = NOW()`,
    [session.id, userId]
  );

  return session;
};

// ─────────────────────────────────────────────────────────────────────────────
// 세션 나가기
// ─────────────────────────────────────────────────────────────────────────────
export const leaveSession = async (userId, sessionId) => {
  await query(
    `UPDATE session_members
     SET left_at = NOW()
     WHERE session_id = $1 AND user_id = $2 AND left_at IS NULL`,
    [sessionId, userId]
  );

  // 실시간 위치 캐시 삭제
  await delCache(`location:${sessionId}:${userId}`);
};

// ─────────────────────────────────────────────────────────────────────────────
// 세션 종료 (호스트만 가능)
// ─────────────────────────────────────────────────────────────────────────────
export const endSession = async (hostUserId, sessionId) => {
  const { rows } = await query(
    `UPDATE sessions
     SET status = 'ended', ended_at = NOW()
     WHERE id = $1 AND host_user_id = $2
     RETURNING *`,
    [sessionId, hostUserId]
  );
  if (rows.length === 0) throw new Error('SESSION_NOT_FOUND_OR_NOT_HOST');

  // 관련 캐시 전부 삭제
  await delCache(`session:${sessionId}`);
  await delCache(`session:code:${rows[0].session_code}`);
  await delPattern(`location:${sessionId}:*`);

  return rows[0];
};

// ─────────────────────────────────────────────────────────────────────────────
// 세션 멤버 목록 조회 (현재 위치 포함)
// ─────────────────────────────────────────────────────────────────────────────
export const getSessionMembers = async (sessionId) => {
  const { rows } = await query(
    `SELECT sm.user_id, sm.joined_at, sm.sharing_enabled,
            CASE WHEN s.host_user_id = sm.user_id THEN 'host' ELSE sm.role END AS role,
            u.nickname, u.avatar_url,
            (s.host_user_id = sm.user_id) AS is_host
     FROM session_members sm
     JOIN users u ON u.id = sm.user_id
     JOIN sessions s ON s.id = sm.session_id
     WHERE sm.session_id = $1 AND sm.left_at IS NULL
     ORDER BY sm.joined_at`,
    [sessionId]
  );

  // 각 멤버의 최신 위치를 Redis에서 조회
  const membersWithLocation = await Promise.all(
    rows.map(async (member) => {
      const location = await getCache(`location:${sessionId}:${member.user_id}`);
      return { ...member, lastLocation: location };
    })
  );

  return membersWithLocation;
};

// ─────────────────────────────────────────────────────────────────────────────
// 멤버 역할 변경 (host/admin만 가능)
// ─────────────────────────────────────────────────────────────────────────────
export const updateMemberRole = async (requesterId, sessionId, targetUserId, newRole) => {
  if (requesterId === targetUserId) throw new Error('CANNOT_CHANGE_OWN_ROLE');
  if (!['admin', 'member'].includes(newRole)) throw new Error('INVALID_ROLE');

  // 세션 정보 + 요청자/대상 역할 한 번에 조회
  const { rows } = await query(
    `SELECT s.host_user_id,
            sm_req.role AS requester_role,
            sm_tgt.user_id AS target_exists
     FROM sessions s
     LEFT JOIN session_members sm_req
       ON sm_req.session_id = s.id AND sm_req.user_id = $2 AND sm_req.left_at IS NULL
     LEFT JOIN session_members sm_tgt
       ON sm_tgt.session_id = s.id AND sm_tgt.user_id = $3 AND sm_tgt.left_at IS NULL
     WHERE s.id = $1`,
    [sessionId, requesterId, targetUserId]
  );
  if (rows.length === 0) throw new Error('SESSION_NOT_FOUND');

  const { host_user_id, requester_role, target_exists } = rows[0];
  if (!target_exists) throw new Error('TARGET_NOT_A_MEMBER');
  if (targetUserId === host_user_id) throw new Error('CANNOT_CHANGE_HOST_ROLE');

  const effectiveRequesterRole = requesterId === host_user_id ? 'host' : requester_role;
  if (!['host', 'admin'].includes(effectiveRequesterRole)) throw new Error('PERMISSION_DENIED');

  await query(
    `UPDATE session_members SET role = $1
     WHERE session_id = $2 AND user_id = $3 AND left_at IS NULL`,
    [newRole, sessionId, targetUserId]
  );
};

// ─────────────────────────────────────────────────────────────────────────────
// 멤버 강제 퇴장 (host/admin만 가능)
// ─────────────────────────────────────────────────────────────────────────────
export const kickMember = async (requesterId, sessionId, targetUserId) => {
  if (requesterId === targetUserId) throw new Error('CANNOT_KICK_YOURSELF');

  const { rows } = await query(
    `SELECT s.host_user_id,
            sm_req.role AS requester_role,
            sm_tgt.role AS target_role,
            sm_tgt.user_id AS target_exists
     FROM sessions s
     LEFT JOIN session_members sm_req
       ON sm_req.session_id = s.id AND sm_req.user_id = $2 AND sm_req.left_at IS NULL
     LEFT JOIN session_members sm_tgt
       ON sm_tgt.session_id = s.id AND sm_tgt.user_id = $3 AND sm_tgt.left_at IS NULL
     WHERE s.id = $1`,
    [sessionId, requesterId, targetUserId]
  );
  if (rows.length === 0) throw new Error('SESSION_NOT_FOUND');

  const { host_user_id, requester_role, target_role, target_exists } = rows[0];
  if (!target_exists) throw new Error('TARGET_NOT_A_MEMBER');

  const effectiveRequesterRole = requesterId === host_user_id ? 'host' : requester_role;
  const effectiveTargetRole    = targetUserId === host_user_id ? 'host' : (target_role ?? 'member');

  if (!['host', 'admin'].includes(effectiveRequesterRole)) throw new Error('PERMISSION_DENIED');
  if (effectiveTargetRole === 'host') throw new Error('CANNOT_KICK_HOST');
  // 관리자는 다른 관리자를 강퇴 불가
  if (effectiveRequesterRole === 'admin' && effectiveTargetRole === 'admin') {
    throw new Error('PERMISSION_DENIED');
  }

  await query(
    `UPDATE session_members SET left_at = NOW()
     WHERE session_id = $1 AND user_id = $2 AND left_at IS NULL`,
    [sessionId, targetUserId]
  );

  await delCache(`location:${sessionId}:${targetUserId}`);
};

// ─────────────────────────────────────────────────────────────────────────────
// 내가 참가 중인 세션 목록
// ─────────────────────────────────────────────────────────────────────────────
export const getMySessions = async (userId) => {
  const { rows } = await query(
    `SELECT s.id, s.session_code, s.name, s.status,
            s.created_at, s.expires_at, s.active_modules, s.module_configs,
            s.host_user_id = $1 AS is_host,
            (SELECT COUNT(*) FROM session_members sm2
             WHERE sm2.session_id = s.id AND sm2.left_at IS NULL) AS member_count
     FROM sessions s
     JOIN session_members sm ON sm.session_id = s.id
     WHERE sm.user_id = $1 AND sm.left_at IS NULL AND s.status = 'active'
     ORDER BY sm.joined_at DESC`,
    [userId]
  );
  return rows;
};

// ─────────────────────────────────────────────────────────────────────────────
// 세션 상세 조회
// ─────────────────────────────────────────────────────────────────────────────
export const getSession = async (sessionId) => {
  const cached = await getCache(`session:${sessionId}`);
  if (cached) return cached;

  const { rows } = await query(
    `SELECT id, host_user_id, session_code, name, status,
            created_at, expires_at, ended_at, active_modules, module_configs
     FROM sessions
     WHERE id = $1`,
    [sessionId]
  );
  if (rows.length === 0) return null;

  await setCache(`session:${sessionId}`, rows[0], 86400);
  return rows[0];
};
