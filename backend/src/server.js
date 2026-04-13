import Fastify from 'fastify';
import fastifyCors from '@fastify/cors';
import fastifyCookie from '@fastify/cookie';
import dotenv from 'dotenv';
import { pathToFileURL } from 'node:url';

import { connectRedis } from './config/redis.js';
import { query as dbQuery } from './config/database.js';
import { initializeMediaServer } from './media/MediaServer.js';
import { createSocketServer } from './websocket/index.js';
import authRoutes from './routes/auth.js';
import sessionRoutes from './routes/sessions.js';
import geofenceRoutes from './routes/geofences.js';
import { startSessionCleaner } from './cron/sessionCleaner.js';

dotenv.config();

const createFastifyApp = async () => {
  const fastify = Fastify({
    logger: {
      level: process.env.NODE_ENV === 'production' ? 'warn' : 'info',
    },
  });

  await fastify.register(fastifyCors, {
    origin: process.env.ALLOWED_ORIGINS?.split(',') || true,
    credentials: true,
  });

  await fastify.register(fastifyCookie);

  fastify.register(authRoutes, { prefix: '/auth' });
  fastify.register(sessionRoutes, { prefix: '/sessions' });
  fastify.register(geofenceRoutes, { prefix: '/sessions' });

  fastify.get('/health', async () => {
    try {
      await dbQuery('SELECT 1');
      return {
        status: 'ok',
        db: 'connected',
        timestamp: new Date().toISOString(),
      };
    } catch {
      return { status: 'error', db: 'disconnected' };
    }
  });

  fastify.setErrorHandler((error, request, reply) => {
    fastify.log.error(error);
    reply.code(500).send({
      error: 'INTERNAL_SERVER_ERROR',
      message: process.env.NODE_ENV === 'development' ? error.message : undefined,
    });
  });

  return fastify;
};

export const startServer = async () => {
  const fastify = await createFastifyApp();
  let io = null;
  let mediaServer = null;

  try {
    await connectRedis();

    await dbQuery('SELECT NOW()');
    console.log('[DB] PostgreSQL connected');

    mediaServer = await initializeMediaServer();
    console.log(`[mediasoup] ${mediaServer.workers.length} workers initialized`);

    await fastify.ready();

    io = createSocketServer(fastify.server, { mediaServer });

    const PORT = Number(process.env.PORT) || 3000;
    const HOST = '0.0.0.0';

    await fastify.listen({ port: PORT, host: HOST });

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
      io?.close();
      await mediaServer?.close();
      await fastify.close();
      process.exit(0);
    };

    process.on('SIGTERM', () => shutdown('SIGTERM'));
    process.on('SIGINT', () => shutdown('SIGINT'));
  } catch (error) {
    console.error('Failed to start server:', error);

    io?.close();
    await mediaServer?.close();
    await fastify.close().catch(() => {});

    process.exit(1);
  }
};

export default startServer;

const isDirectRun =
  process.argv[1] != null &&
  import.meta.url === pathToFileURL(process.argv[1]).href;

if (isDirectRun) {
  startServer();
}
