import { GoogleGenerativeAI } from '@google/generative-ai';

import { chat } from './LLMClient.js';
import { SYSTEM_PROMPT, PROMPTS } from './prompt.js';
import { retrieve } from './rag/ragRetriever.js';
import { GamePluginRegistry } from '../game/index.js';
import { redisClient } from '../config/redis.js';

const PRIMARY_MODEL = 'gemini-2.5-flash';
const RETRY_DELAYS_MS = [1000, 2000, 4000];

const MAX_TURNS = 10;
const HISTORY_TTL_SECONDS = 60 * 60 * 24;
// Redis 키 프리픽스
const COOLDOWN_PREFIX = 'ai:cooldown:';
const HISTORY_PREFIX  = 'ai:history:';

/**
 * Redis SET + EX 기반 쿨다운 체크.
 * 키가 이미 존재하면 쿨다운 중(true), 없으면 키를 심고 false 반환.
 */
async function isOnCooldown(key, ms = 5000) {
  const redisKey = `${COOLDOWN_PREFIX}${key}`;
  const ttlSeconds = Math.ceil(ms / 1000);
  // SET NX EX: 키가 없을 때만 삽입. 삽입 성공 → 쿨다운 아님, null 반환 → 쿨다운 중
  const result = await redisClient.set(redisKey, '1', { NX: true, EX: ttlSeconds });
  return result === null; // null이면 이미 존재(쿨다운 중)
}

/**
 * Redis List(LPUSH)에서 대화 기록 읽기.
 * LPUSH는 최신을 앞에 저장하므로 LRANGE 후 reverse해 시간순으로 반환.
 */
async function getHistory(roomId, userId) {
  const key = `${HISTORY_PREFIX}${roomId}:${userId}`;
  const items = await redisClient.lRange(key, 0, -1);
  return items.reverse().map((item) => JSON.parse(item));
}

/**
 * Redis List(LPUSH)에 메시지 추가 후 LTRIM으로 MAX_TURNS 유지.
 * LPUSH 특성상 최신 항목이 인덱스 0에 위치하며, LTRIM 0 ~(MAX_TURNS*2-1)로 잘라낸다.
 */
async function addHistory(roomId, userId, role, content) {
  const key = `${HISTORY_PREFIX}${roomId}:${userId}`;
  await redisClient.lPush(key, JSON.stringify({ role, content }));
  await redisClient.lTrim(key, 0, MAX_TURNS * 2 - 1);
  await redisClient.expire(key, HISTORY_TTL_SECONDS);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function isGeminiCredentialError(error) {
  const message = `${error?.message ?? ''}`;
  return (
    message.includes('API key was reported as leaked') ||
    message.includes('403 Forbidden') ||
    message.includes('API_KEY_INVALID') ||
    message.includes('PERMISSION_DENIED')
  );
}

function isGeminiOverloadError(error) {
  const message = `${error?.message ?? ''}`;
  return (
    error?.status === 503 ||
    error?.statusCode === 503 ||
    message.includes('503 Service Unavailable') ||
    message.includes('currently experiencing high demand') ||
    message.includes('UNAVAILABLE')
  );
}

function createGenerativeModel(model, systemPrompt) {
  return new GoogleGenerativeAI(process.env.GEMINI_API_KEY).getGenerativeModel({
    model,
    systemInstruction: systemPrompt,
  });
}

async function askWithModel({ model, systemPrompt, history, question }) {
  const chatSession = createGenerativeModel(model, systemPrompt).startChat({
    history,
    generationConfig: {
      maxOutputTokens: 850,
      temperature: 0.7,
    },
  });

  const result = await chatSession.sendMessage(question);
  return result.response.text().trim();
}

async function askWithRetry({ systemPrompt, history, question }) {
  let lastError = null;
  const attempts = RETRY_DELAYS_MS.length + 1;

  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    if (attempt > 1) {
      const delay =
        RETRY_DELAYS_MS[Math.min(attempt - 2, RETRY_DELAYS_MS.length - 1)];
      console.warn(
        `[AIDirector.ask] ${PRIMARY_MODEL} retry ${attempt - 1}/${attempts - 1} after ${delay}ms`,
      );
      await sleep(delay);
    }

    try {
      return await askWithModel({
        model: PRIMARY_MODEL,
        systemPrompt,
        history,
        question,
      });
    } catch (error) {
      lastError = error;

      if (isGeminiCredentialError(error)) {
        throw error;
      }

      const canRetryCurrentModel =
        isGeminiOverloadError(error) && attempt < attempts;
      if (canRetryCurrentModel) {
        continue;
      }

      break;
    }
  }

  throw lastError ?? new Error('Gemini request failed');
}

function buildAskFailure(error) {
  if (!process.env.GEMINI_API_KEY || isGeminiCredentialError(error)) {
    return {
      answer:
        'AI MOYA가 지금은 오프라인 상태입니다. Gemini API 키가 차단되었거나 교체가 필요합니다. 운영 키가 갱신되면 다시 질문할 수 있습니다.',
      sources: [],
      isError: true,
      errorCode: 'AI_KEY_INVALID',
    };
  }

  if (isGeminiOverloadError(error)) {
    return {
      answer:
        'AI MOYA 요청이 잠시 몰려서 답변이 지연되고 있습니다. 잠시 후 다시 질문해 주세요.',
      sources: [],
      isError: true,
      errorCode: 'AI_TEMPORARILY_BUSY',
    };
  }

  return {
    answer: 'AI MOYA가 잠시 응답하지 못했습니다. 잠시 후 다시 질문해 주세요.',
    sources: [],
    isError: true,
    errorCode: 'AI_UNAVAILABLE',
  };
}

async function ask(room, player, question) {
  try {
    if (!process.env.GEMINI_API_KEY) {
      return buildAskFailure(new Error('Missing GEMINI_API_KEY'));
    }

    const plugin = GamePluginRegistry.get(room.gameType || 'among_us');
    const phase = plugin.getCurrentPhase(room);

    const { context, sources, found } = await retrieve(
      question,
      room.gameType,
      player.team === 'impostor' ? 'impostor' : 'crew',
      phase,
    );

    const systemPrompt = [
      plugin.getSystemPrompt(player.roleId, player.nickname),
      found ? `\n[관련 게임 규칙]\n${context}` : '',
      `\n[현재 게임 상황]\n${plugin.buildStateContext(room, player)}`,
    ].join('\n');

    // Redis에서 전체 기록 로드 후 Gemini 포맷으로 변환
    const allHistory = (await getHistory(room.roomId, player.userId)).map((message) => ({
      role: message.role === 'assistant' ? 'model' : 'user',
      parts: [{ text: message.content }],
    }));

    // 토큰 절감: Gemini에는 최신 4개 항목(≈2턴)만 주입
    const history = allHistory.slice(-4);

    const answer = await askWithRetry({
      systemPrompt,
      history,
      question,
    });

    await addHistory(room.roomId, player.userId, 'user', question);
    await addHistory(room.roomId, player.userId, 'assistant', answer);

    return { answer, sources, isError: false };
  } catch (error) {
    console.error('[AIDirector.ask] error:', error.message);
    return buildAskFailure(error);
  }
}

async function clearHistory(roomId, userId) {
  await redisClient.del(`${HISTORY_PREFIX}${roomId}:${userId}`);
}

async function cleanupRoom(roomId) {
  // KEYS는 소규모 데이터에 한해 허용; 대규모 환경에서는 SCAN으로 교체 권장
  const keys = await redisClient.keys(`${HISTORY_PREFIX}${roomId}:*`);
  if (keys.length > 0) {
    await redisClient.del(keys);
  }
}

async function onGameStart(room) {
  const playerCount = room.players?.size ?? room.players?.length ?? 0;
  const impostorCount =
    room.impostors?.length ??
    [...(room.players?.values?.() ?? [])].filter(
      (player) => player.team === 'impostor',
    ).length;

  return chat({
    prompt: PROMPTS.gameStart(playerCount, impostorCount),
    systemPrompt: SYSTEM_PROMPT,
    model: 'fast',
  });
}

async function onKill(room, killer, target) {
  if (await isOnCooldown(`${room.roomId}_kill`, 3000)) return null;

  const alivePlayerIds = room.alivePlayerIds ?? [];
  const impostors = room.impostors ?? [];
  const remainingCrew =
    room.aliveCrew?.length ??
    alivePlayerIds.filter((id) => !impostors.includes(id)).length;
  const remainingImpostors =
    room.aliveImpostors?.length ??
    alivePlayerIds.filter((id) => impostors.includes(id)).length;

  return chat({
    prompt: PROMPTS.kill(
      target.nickname,
      target.zone,
      room.killLog.length,
      remainingCrew,
      remainingImpostors,
    ),
    systemPrompt: SYSTEM_PROMPT,
    model: 'fast',
  });
}

async function onMeeting(room, caller, reason, body = null) {
  const prompt =
    reason === 'report' && body
      ? PROMPTS.bodyReport(
          caller.nickname,
          body.nickname,
          body.zone,
          room.meetingCount,
        )
      : PROMPTS.emergencyMeeting(caller.nickname, room.meetingCount);

  return chat({ prompt, systemPrompt: SYSTEM_PROMPT, model: 'fast' });
}

async function onVoteResult(room, result, ejected) {
  const cooldownGuide = '다음 투표는 30초 뒤에 다시 열립니다.';

  if (!ejected) {
    if (result.isTied) {
      return `AI MOYA: 투표 결과 동점으로 아무도 추방되지 않았습니다. ${cooldownGuide}`;
    }
    return `AI MOYA: 투표 결과 아무도 추방되지 않았습니다. ${cooldownGuide}`;
  }

  const nickname = ejected.nickname ?? ejected.userId ?? '플레이어';
  const voteCount =
    typeof result.topCount === 'number' && result.topCount > 0
      ? `${result.topCount}표로 `
      : '';

  if (result.wasImpostor) {
    return `AI MOYA: 투표 결과 ${nickname}님이 ${voteCount}추방되었습니다. 정체는 임포스터였습니다. ${cooldownGuide}`;
  }

  return `AI MOYA: 투표 결과 ${nickname}님이 ${voteCount}추방되었습니다. 정체는 크루원이었습니다. ${cooldownGuide}`;
}

async function onGameEnd(room, result) {
  const allImpostors = [...room.players.values()]
    .filter((player) => player.team === 'impostor')
    .map((player) => player.nickname);

  const prompt =
    result.winner === 'crew'
      ? PROMPTS.crewWin(result.reason, allImpostors)
      : PROMPTS.impostorWin(allImpostors);

  return chat({ prompt, systemPrompt: SYSTEM_PROMPT, model: 'fast' });
}

export {
  ask,
  clearHistory,
  cleanupRoom,
  onGameStart,
  onKill,
  onMeeting,
  onVoteResult,
  onGameEnd,
};
