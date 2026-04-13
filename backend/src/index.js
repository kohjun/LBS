// src/index.js
import Fastify from 'fastify';
import fastifyCors from '@fastify/cors';
import fastifyCookie from '@fastify/cookie';
import dotenv from 'dotenv';

import { connectRedis } from './config/redis.js';
import { query as dbQuery } from './config/database.js';
import { createSocketServer } from './websocket/index.js';
import authRoutes from './routes/auth.js';
import sessionRoutes from './routes/sessions.js';
import geofenceRoutes from './routes/geofences.js';
import { startSessionCleaner } from './cron/sessionCleaner.js';

dotenv.config();

const fastify = Fastify({
  logger: {
    level: process.env.NODE_ENV === 'production' ? 'warn' : 'info',
  },
});

// 플러그인 등록
await fastify.register(fastifyCors, {
  origin: process.env.ALLOWED_ORIGINS?.split(',') || true,
  credentials: true,
});

await fastify.register(fastifyCookie);

// 라우트 등록
fastify.register(authRoutes,     { prefix: '/auth' });
fastify.register(sessionRoutes,  { prefix: '/sessions' });
fastify.register(geofenceRoutes, { prefix: '/geofences' });

// 헬스체크
fastify.get('/health', async () => {
  try {
    await dbQuery('SELECT 1');
    return { status: 'ok', db: 'connected', timestamp: new Date().toISOString() };
  } catch {
    return { status: 'error', db: 'disconnected' };
  }
});

// 에러 핸들러
fastify.setErrorHandler((error, request, reply) => {
  fastify.log.error(error);
  reply.code(500).send({
    error: 'INTERNAL_SERVER_ERROR',
    message: process.env.NODE_ENV === 'development' ? error.message : undefined,
  });
});

// 서버 시작
const start = async () => {
  try {
    // connectRedis, DB 연결 확인, fastify 플러그인 준비는 상호 독립적 → 병렬 실행
    await Promise.all([
      connectRedis(),
      dbQuery('SELECT NOW()').then(() => console.log('[DB] PostgreSQL connected')),
      fastify.ready(),
    ]);

    // Socket.IO를 Fastify 내부 서버에 직접 붙이기
    const io = createSocketServer(fastify.server);

    const PORT = Number(process.env.PORT) || 3000;
    const HOST = '0.0.0.0';

    // Fastify로 직접 리슨
    await fastify.listen({ port: PORT, host: HOST });

    // 스케줄러 실행 (io 객체 전달)
    startSessionCleaner(io);

    console.log(`
============================================
  Location Sharing Server Started
  REST API : http://${HOST}:${PORT} 
  WebSocket: ws://${HOST}:${PORT}
  Env      : ${process.env.NODE_ENV}
============================================
    `);

    const shutdown = async (signal) => {
      console.log(`\n[${signal}] Shutting down...`);
      io.close();
      await fastify.close();
      process.exit(0);
    };

    process.on('SIGTERM', () => shutdown('SIGTERM'));
    process.on('SIGINT',  () => shutdown('SIGINT'));

  } catch (err) {
    console.error('Failed to start server:', err);
    process.exit(1);
  }
};

start();