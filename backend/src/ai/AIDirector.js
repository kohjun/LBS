import { GoogleGenerativeAI } from '@google/generative-ai';

import { chat } from './LLMClient.js';
import { SYSTEM_PROMPT, PROMPTS } from './prompt.js';
import { retrieve } from './rag/ragRetriever.js';
import { GamePluginRegistry } from '../game/index.js';

const genAI = new GoogleGenerativeAI(process.env.GEMINI_API_KEY);

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

function isGeminiCredentialError(error) {
  const message = `${error?.message ?? ''}`;
  return (
    message.includes('API key was reported as leaked') ||
    message.includes('403 Forbidden') ||
    message.includes('API_KEY_INVALID') ||
    message.includes('PERMISSION_DENIED')
  );
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

  return {
    answer: 'AI MOYA가 잠시 응답하지 못했습니다. 잠시 뒤 다시 질문해 주세요.',
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

    const genModel = genAI.getGenerativeModel({
      model: 'gemini-2.5-flash',
      systemInstruction: systemPrompt,
    });

    const history = getHistory(room.roomId, player.userId).map((message) => ({
      role: message.role === 'assistant' ? 'model' : 'user',
      parts: [{ text: message.content }],
    }));

    const chatSession = genModel.startChat({
      history,
      generationConfig: {
        maxOutputTokens: 500,
        temperature: 0.7,
      },
    });

    const result = await chatSession.sendMessage(question);
    const answer = result.response.text().trim();

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
  return chat({
    prompt: PROMPTS.gameStart(room.players.size),
    systemPrompt: SYSTEM_PROMPT,
    model: 'fast',
  });
}

async function onKill(room, killer, target) {
  if (isOnCooldown(`${room.roomId}_kill`, 3000)) return null;

  return chat({
    prompt: PROMPTS.kill(
      target.nickname,
      target.zone,
      room.killLog.length,
      room.aliveCrew?.length ?? 0,
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
  const cooldownGuide = '다음 투표는 30초 뒤에 다시 열 수 있습니다.';

  if (!ejected) {
    if (result.isTied) {
      return `AI MOYA: 투표 결과 동점이 나와 아무도 추방되지 않았습니다. ${cooldownGuide}`;
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
