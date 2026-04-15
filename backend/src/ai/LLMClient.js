// src/ai/LLMClient.js
//
// ┌─────────────────────────────────────────────────────────┐
// │  LLMClient class  – 게임 로직 검증용 JSON 응답 클라이언트  │
// │  chat()  – 기존 AIDirector narrative 호환 함수            │
// └─────────────────────────────────────────────────────────┘

import { GeminiProvider } from './providers/GeminiProvider.js';
import { LocalProvider }  from './providers/LocalProvider.js';

// ── 검증 Fallback ────────────────────────────────────────────────────────────
const FALLBACK_VALIDATION = Object.freeze({
  action:     'allow',
  reason:     '시스템 통신 지연으로 인해 자동으로 승인되었습니다.',
  confidence: 1.0,
});

// ── 검증 클라이언트 ──────────────────────────────────────────────────────────

export class LLMClient {
  constructor() {
    this._provider =
      process.env.LLM_PROVIDER === 'local'
        ? new LocalProvider()
        : new GeminiProvider();

    console.info(
      `[LLMClient] provider=${process.env.LLM_PROVIDER === 'local' ? 'local' : 'gemini'}`,
    );
  }

  /**
   * 게임 로직 검증 요청.
   * Provider 응답에서 JSON 객체만 추출하고, 파싱 실패 시 Fallback 을 반환합니다.
   *
   * @param {string} systemPrompt
   * @param {string} userPrompt
   * @returns {Promise<{ action: string, reason: string, confidence: number }>}
   */
  async chat(systemPrompt, userPrompt) {
    try {
      const text = await this._provider.generateResponse(systemPrompt, userPrompt);

      // 소형 모델이 ```json ... ``` 마크다운을 섞어 보낼 경우를 대비해
      // 중괄호 블록만 추출하여 파싱한다.
      const match   = text.match(/\{[\s\S]*\}/);
      const jsonStr = match ? match[0] : text;

      return JSON.parse(jsonStr);
    } catch (err) {
      console.warn('[LLMClient] validation error, returning fallback:', err.message);
      return { ...FALLBACK_VALIDATION };
    }
  }
}

// ── 기본 인스턴스 ─────────────────────────────────────────────────────────────
const llmClient = new LLMClient();
export default llmClient;

// ─────────────────────────────────────────────────────────────────────────────
// 하위 호환 narrative chat (AIDirector.js 에서 import { chat } 으로 사용)
// Gemini 를 항상 사용하며 기존 재시도·Fallback 동작을 유지합니다.
// ─────────────────────────────────────────────────────────────────────────────

const _narProvider = new GeminiProvider();

const MAX_RETRIES   = 3;
const RETRY_DELAYS  = [1000, 2000, 4000];

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function is503(err) {
  return (
    err?.status === 503 ||
    err?.statusCode === 503 ||
    (typeof err?.message === 'string' && err.message.includes('503'))
  );
}

function getFallbackMessage(prompt) {
  if (prompt.includes('kill'))    return 'A new sign of danger is in the air...';
  if (prompt.includes('meeting')) return 'An emergency meeting has begun.';
  if (prompt.includes('vote'))    return 'The vote result is being finalized.';
  if (prompt.includes('mission')) return 'Keep moving on your mission.';
  return 'AI MOYA is watching the situation...';
}

/**
 * 내러티브 텍스트 생성 (AIDirector.js 전용 하위 호환 API).
 * 항상 Gemini 를 사용하고 string 을 반환합니다.
 *
 * @param {{ prompt: string, systemPrompt: string, model?: string, maxTokens?: number }} opts
 * @returns {Promise<string>}
 */
async function chat({ prompt, systemPrompt, model = 'fast', maxTokens = 500 }) {
  for (let attempt = 0; attempt <= MAX_RETRIES; attempt += 1) {
    if (attempt > 0) {
      const delay = RETRY_DELAYS[attempt - 1];
      console.warn(`[LLM] 503 retry (${attempt}/${MAX_RETRIES}) after ${delay}ms`);
      await sleep(delay);
    }

    try {
      return await _narProvider.generateResponse(systemPrompt, prompt, {
        maxTokens,
        temperature: 0.8,
      });
    } catch (err) {
      const shouldRetry = is503(err) && attempt < MAX_RETRIES;
      if (shouldRetry) continue;

      console.error('[LLM] API error:', err.message);
      return getFallbackMessage(prompt);
    }
  }

  return getFallbackMessage(prompt);
}

export { chat };
