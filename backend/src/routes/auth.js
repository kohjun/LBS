// src/routes/auth.js
import { z } from 'zod';
import * as authService from '../services/authService.js';
import { saveFcmToken } from '../services/fcmService.js';
import { signAccessToken, authenticate } from '../middleware/auth.js';
import { query } from '../config/database.js';

// 입력 유효성 검사 스키마
const registerSchema = z.object({
  email:    z.string().email(),
  password: z.string().min(8).max(100),
  nickname: z.string().min(2).max(30),
});

const loginSchema = z.object({
  email:    z.string().email(),
  password: z.string().min(1),
});

export default async function authRoutes(fastify) {

  // ── POST /auth/register ──────────────────────────────────────────────────
  fastify.post('/register', async (request, reply) => {
    const parsed = registerSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: 'VALIDATION_ERROR', details: parsed.error.issues });
    }

    try {
      const user = await authService.register(parsed.data);
      return reply.code(201).send({ message: 'User created', user });
    } catch (err) {
      if (err.message === 'EMAIL_ALREADY_EXISTS') {
        return reply.code(409).send({ error: 'EMAIL_ALREADY_EXISTS' });
      }
      throw err;
    }
  });

  // ── POST /auth/login ─────────────────────────────────────────────────────
  fastify.post('/login', async (request, reply) => {
    const parsed = loginSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: 'VALIDATION_ERROR' });
    }

    try {
      const user = await authService.login(parsed.data);

      // Access Token (단명, 15분)
      const accessToken = signAccessToken(user);

      // Refresh Token (장명, 7일) → HttpOnly 쿠키
      const refreshToken = await authService.createRefreshToken(user.id);

      reply.setCookie('refreshToken', refreshToken, {
        httpOnly: true,         // JS 접근 불가
        secure: process.env.NODE_ENV === 'production',
        sameSite: 'Strict',
        maxAge: 7 * 24 * 60 * 60, // 7일 (초)
        path: '/auth',            // /auth 경로에서만 전송
      });

      return reply.send({
        accessToken,
        user: {
          id: user.id,
          email: user.email,
          nickname: user.nickname,
          avatar_url: user.avatar_url,
        },
      });
    } catch (err) {
      if (err.message === 'INVALID_CREDENTIALS') {
        return reply.code(401).send({ error: 'INVALID_CREDENTIALS' });
      }
      throw err;
    }
  });

  // ── POST /auth/refresh ───────────────────────────────────────────────────
  // 만료된 Access Token 갱신 (쿠키의 Refresh Token 사용)
  fastify.post('/refresh', async (request, reply) => {
    // 쿠키 또는 body 양쪽에서 읽음 (모바일 백그라운드 서비스 지원)
    const rawRefreshToken =
      request.cookies?.refreshToken || request.body?.refreshToken;
    if (!rawRefreshToken) {
      return reply.code(401).send({ error: 'MISSING_REFRESH_TOKEN' });
    }

    try {
      const { user, newRefreshToken } = await authService.rotateRefreshToken(rawRefreshToken);
      const accessToken = signAccessToken(user);

      // 새 Refresh Token으로 쿠키 교체
      reply.setCookie('refreshToken', newRefreshToken, {
        httpOnly: true,
        secure: process.env.NODE_ENV === 'production',
        sameSite: 'Strict',
        maxAge: 7 * 24 * 60 * 60,
        path: '/auth',
      });

      // body에도 포함 (Flutter 백그라운드 서비스에서 쿠키 없이 저장 가능하도록)
      return reply.send({
        accessToken,
        refreshToken: newRefreshToken,
        user: {
          id:         user.id,
          email:      user.email,
          nickname:   user.nickname,
          avatar_url: user.avatar_url,
        },
      });
    } catch (err) {
      const errorMap = {
        INVALID_REFRESH_TOKEN: 401,
        REFRESH_TOKEN_EXPIRED:  401,
        REFRESH_TOKEN_REUSE_DETECTED: 401,
      };
      const statusCode = errorMap[err.message] || 500;
      return reply.code(statusCode).send({ error: err.message });
    }
  });

  // ── POST /auth/logout ────────────────────────────────────────────────────
  fastify.post('/logout', { preHandler: [authenticate] }, async (request, reply) => {
    const rawRefreshToken = request.cookies?.refreshToken;
    if (rawRefreshToken) {
      await authService.logout(rawRefreshToken);
    }

    reply.clearCookie('refreshToken', { path: '/auth' });
    return reply.send({ message: 'Logged out' });
  });

  // ── GET /auth/me ─────────────────────────────────────────────────────────
  fastify.get('/me', { preHandler: [authenticate] }, async (request, reply) => {
    const user = await authService.getUserById(request.user.id);
    if (!user) return reply.code(404).send({ error: 'USER_NOT_FOUND' });
    return reply.send({ user });
  });

  // ── POST /auth/fcm-token ──────────────────────────────────────────────────
  // 앱 시작 또는 토큰 갱신 시 FCM 토큰을 서버에 등록
  fastify.post('/fcm-token', { preHandler: [authenticate] }, async (request, reply) => {
    const parsed = z.object({
      fcm_token: z.string().min(1).max(500),
    }).safeParse(request.body);

    if (!parsed.success) {
      return reply.code(400).send({ error: 'VALIDATION_ERROR' });
    }

    await saveFcmToken(request.user.id, parsed.data.fcm_token);
    return reply.send({ message: 'FCM token registered' });
  });

  // ── PATCH /auth/fcm-token ─────────────────────────────────────────────────
  // FCM 토큰 갱신 (Flutter onTokenRefresh 콜백에서 호출)
  fastify.patch('/fcm-token', { preHandler: [authenticate] }, async (request, reply) => {
    const { token } = request.body ?? {};
    if (!token || typeof token !== 'string' || token.trim() === '') {
      return reply.code(400).send({ error: 'VALIDATION_ERROR' });
    }

    await query(
      'UPDATE users SET fcm_token = $1 WHERE id = $2',
      [token.trim(), request.user.id]
    );

    return reply.send({ updated: true });
  });
}
