// src/ai/providers/GeminiProvider.js
//
// Google Gemini API 래퍼.
// LLMClient 및 기존 narrative chat 양쪽에서 사용됩니다.

import { GoogleGenerativeAI } from '@google/generative-ai';

export class GeminiProvider {
  constructor() {
    this._genAI = new GoogleGenerativeAI(process.env.GEMINI_API_KEY);
    this._model = process.env.GEMINI_MODEL ?? 'gemini-2.5-flash';
  }

  /**
   * @param {string} systemPrompt
   * @param {string} userPrompt
   * @param {{ maxTokens?: number, temperature?: number }} [options]
   * @returns {Promise<string>} raw text response
   */
  async generateResponse(systemPrompt, userPrompt, options = {}) {
    const { maxTokens = 600, temperature = 0.3 } = options;

    const model = this._genAI.getGenerativeModel({
      model: this._model,
      systemInstruction: systemPrompt,
    });

    const result = await model.generateContent({
      contents: [{ role: 'user', parts: [{ text: userPrompt }] }],
      generationConfig: { maxOutputTokens: maxTokens, temperature },
    });

    return result.response.text().trim();
  }
}
