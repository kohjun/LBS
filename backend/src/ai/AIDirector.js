import { GoogleGenerativeAI } from '@google/generative-ai';

import { chat } from './LLMClient.js';
import { SYSTEM_PROMPT, PROMPTS } from './prompt.js';
import { retrieve } from './rag/ragRetriever.js';
import { GamePluginRegistry } from '../game/index.js';

const PRIMARY_MODEL = 'gemini-2.5-flash';
const RETRY_DELAYS_MS = [1000, 2000, 4000];

const cooldowns = new Map();
const conversationHistory = new Map();
const MAX_TURNS = 10;

function isOnCooldown(key, ms = 5000) {
  const last = cooldowns.get(key) || 0;
  if (Date.now() - last < ms) return true;
  cooldowns.set(key, Date.now());
  return false;
}

function getHistory(roomId, userId) {
  const key = `${roomId}_${userId}`;
  if (!conversationHistory.has(key)) {
    conversationHistory.set(key, []);
  }
  return conversationHistory.get(key);
}

function addHistory(roomId, userId, role, content) {
  const history = getHistory(roomId, userId);
  history.push({ role, content });
  if (history.length > MAX_TURNS * 2) {
    history.splice(0, 2);
  }
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

    const history = getHistory(room.roomId, player.userId).map((message) => ({
      role: message.role === 'assistant' ? 'model' : 'user',
      parts: [{ text: message.content }],
    }));

    const answer = await askWithRetry({
      systemPrompt,
      history,
      question,
    });

    addHistory(room.roomId, player.userId, 'user', question);
    addHistory(room.roomId, player.userId, 'assistant', answer);

    return { answer, sources, isError: false };
  } catch (error) {
    console.error('[AIDirector.ask] error:', error.message);
    return buildAskFailure(error);
  }
}

function clearHistory(roomId, userId) {
  conversationHistory.delete(`${roomId}_${userId}`);
}

function cleanupRoom(roomId) {
  for (const key of conversationHistory.keys()) {
    if (key.startsWith(`${roomId}_`)) {
      conversationHistory.delete(key);
    }
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
  if (isOnCooldown(`${room.roomId}_kill`, 3000)) return null;

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
