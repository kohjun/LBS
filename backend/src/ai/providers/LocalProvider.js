// src/ai/providers/LocalProvider.js
//
// 로컬 LLM (Ollama OpenAI 호환 엔드포인트) 래퍼.
// 소형 모델(gemma4:e2b) 대상으로 temperature 0.1, max_tokens 150 으로 빠른 판별에 최적화.

export class LocalProvider {
  constructor() {
    this._baseUrl = process.env.LOCAL_LLM_URL ?? 'http://localhost:11434/v1';
    this._model   = process.env.LOCAL_LLM_MODEL ?? 'gemma4:e2b';
  }

  /**
   * @param {string} systemPrompt
   * @param {string} userPrompt
   * @param {{ maxTokens?: number, temperature?: number }} [options]
   * @returns {Promise<string>} raw text response
   */
  async generateResponse(systemPrompt, userPrompt, options = {}) {
    const { maxTokens = 150, temperature = 0.3 } = options;

    const response = await fetch(`${this._baseUrl}/chat/completions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: this._model,
        messages: [
          { role: 'system', content: systemPrompt },
          { role: 'user',   content: userPrompt },
        ],
        temperature,
        max_tokens: maxTokens,
      }),
    });

    if (!response.ok) {
      throw new Error(`Local LLM HTTP ${response.status}: ${response.statusText}`);
    }

    const data = await response.json();
    const text = data.choices?.[0]?.message?.content?.trim();

    if (!text) {
      throw new Error('Local LLM returned empty content');
    }

    return text;
  }
}
