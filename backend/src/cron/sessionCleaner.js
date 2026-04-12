// src/cron/sessionCleaner.js

import cron from 'node-cron';
import { query, withTransaction } from '../config/database.js';
import { delCache, delPattern } from '../config/redis.js';

export const startSessionCleaner = (io) => {
  // 매 10분마다 실행 (성능을 위해 1분 -> 10분 단위로 조정 권장)
  cron.schedule('*/10 * * * *', async () => {
    try {
      // 1. 만료 시간이 지났고 아직 'active' 상태인 세션 찾기
      const { rows: expiredSessions } = await query(`
        SELECT id, session_code 
        FROM sessions 
        WHERE status = 'active' AND expires_at <= NOW()
      `);

      if (expiredSessions.length === 0) return;

      console.log(`[Cron] 만료된 세션 ${expiredSessions.length}개를 발견했습니다. 정리를 시작합니다.`);

      for (const session of expiredSessions) {
        const sessionId = session.id;
        const sessionCode = session.session_code;

        // 2. 트랜잭션으로 DB 상태 완벽하게 정리
        await withTransaction(async (client) => {
          // 세션 상태를 'ended'로 변경
          await client.query(`
            UPDATE sessions 
            SET status = 'ended', ended_at = NOW() 
            WHERE id = $1
          `, [sessionId]);

          // 해당 세션의 멤버들 퇴장 처리
          await client.query(`
            UPDATE session_members 
            SET left_at = NOW() 
            WHERE session_id = $1 AND left_at IS NULL
          `, [sessionId]);

          // 해당 세션에 묶여있던 유저들의 1인 1방 락(Lock) 해제
          await client.query(`
            UPDATE users 
            SET current_session_id = NULL 
            WHERE current_session_id = $1
          `, [sessionId]);
        });

        // 3. Redis 캐시 및 모든 게임 관련 찌꺼기 데이터(Zombie Data) 삭제
        // 단일 키 삭제
        await delCache(`session:${sessionId}`);
        await delCache(`session:code:${sessionCode}`);
        await delCache(`game:${sessionId}`);
        
        // 패턴 키 일괄 삭제 (기존 위치 캐시 + 신규 게임 모듈 캐시들)
        const patternsToDelete = [
          `location:${sessionId}:*`,
          `prox:${sessionId}:*`,
          `eliminated:${sessionId}:*`,
          `target_lock:${sessionId}:*`,
          `kill_lock:${sessionId}:*`,
          `round:${sessionId}:*`,
          `tag:${sessionId}:*`,
          `throttle:ai:${sessionId}:*`,
          `throttle:geo:${sessionId}:*`
        ];

        // 병렬로 모든 패턴 삭제 실행
        await Promise.all(
          patternsToDelete.map(pattern => delPattern(pattern))
        );

        // 4. Socket.io로 클라이언트에 만료 알림 발송 및 소켓 강제 퇴장
        if (io) {
          // 방에 있는 모든 사람에게 만료 이벤트 쏘기
          io.to(`session:${sessionId}`).emit('sessionExpired', {
            sessionId,
            message: '설정된 세션 시간이 만료되어 방이 자동으로 종료되었습니다.'
          });

          // 서버 단에서 해당 룸(Room)에 속한 소켓들을 강제로 방에서 내보내기
          const sockets = await io.in(`session:${sessionId}`).fetchSockets();
          for (const socket of sockets) {
            socket.leave(`session:${sessionId}`);
          }
        }
        
        console.log(`[Cron] 세션(${sessionCode}) DB 정리 및 Redis 게임 데이터 완벽 삭제 완료.`);
      }
    } catch (error) {
      console.error('[Cron] 세션 자동 만료 처리 중 오류 발생:', error);
    }
  });
  
  console.log('[Cron] 세션 자동 만료 스케줄러가 시작되었습니다.');
};