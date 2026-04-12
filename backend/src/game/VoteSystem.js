import EventBus from './EventBus.js';

const VOTE_PHASE = {
  DISCUSSION: 'discussion',
  VOTING: 'voting',
  RESULT: 'result',
  ENDED: 'ended',
};

const MEETING_COOLDOWN_MS = 30000;

const getMemberUserId = (member) => member?.userId ?? member?.user_id ?? null;

class VoteSession {
  constructor({ sessionId, callerId, bodyId, reason, settings = {} }) {
    this.sessionId = sessionId;
    this.callerId = callerId;
    this.bodyId = bodyId ?? null;
    this.reason = reason;
    this.phase = VOTE_PHASE.DISCUSSION;
    this.votes = new Map();
    this.preVotes = new Map();
    this.result = null;
    this._timers = [];
    this.discussionTime = settings.discussion_time ?? 90;
    this.voteTime = settings.vote_time ?? 30;
    this.totalPlayers = settings.totalPlayers ?? 0;
  }

  submitPreVote(voterId, targetId) {
    if (this.phase !== VOTE_PHASE.DISCUSSION) {
      throw new Error(`사전투표는 토론 단계에서만 가능합니다. 현재 단계: ${this.phase}`);
    }
    if (voterId === targetId) {
      throw new Error('자기 자신에게는 투표할 수 없습니다.');
    }

    this.preVotes.set(voterId, targetId);
  }

  submitVote(voterId, targetId) {
    if (this.phase !== VOTE_PHASE.VOTING) {
      throw new Error(`아직 투표 단계가 아닙니다. 현재 단계: ${this.phase}`);
    }
    if (voterId === targetId) {
      throw new Error('자기 자신에게는 투표할 수 없습니다.');
    }
    if (this.votes.has(voterId)) {
      throw new Error('이미 투표했습니다.');
    }

    this.votes.set(voterId, targetId);
  }

  isAllVoted(alivePlayers) {
    return alivePlayers.every((player) => {
      const playerId = getMemberUserId(player);
      return playerId != null && this.votes.has(playerId);
    });
  }

  applyPreVotes() {
    for (const [voterId, targetId] of this.preVotes.entries()) {
      if (!this.votes.has(voterId)) {
        this.votes.set(voterId, targetId);
      }
    }
  }

  tally(alivePlayers) {
    const counts = new Map();

    for (const player of alivePlayers) {
      const playerId = getMemberUserId(player);
      if (!playerId) continue;

      const target = this.votes.get(playerId) ?? 'skip';
      counts.set(target, (counts.get(target) ?? 0) + 1);
    }

    let topTarget = null;
    let topCount = 0;
    let isTied = false;

    for (const [target, count] of counts.entries()) {
      if (target === 'skip') continue;

      if (count > topCount) {
        topTarget = target;
        topCount = count;
        isTied = false;
      } else if (count === topCount) {
        isTied = true;
      }
    }

    const ejected = !isTied && topTarget ? topTarget : null;

    return {
      voteCount: Object.fromEntries(counts),
      topTarget,
      topCount,
      isTied,
      ejected,
      totalVotes: alivePlayers.length,
    };
  }

  moveToVoting() {
    this.phase = VOTE_PHASE.VOTING;
  }

  moveToResult(result) {
    this.phase = VOTE_PHASE.RESULT;
    this.result = result;
  }

  end() {
    this.phase = VOTE_PHASE.ENDED;
    this._clearTimers();
  }

  addTimer(handle) {
    this._timers.push(handle);
  }

  _clearTimers() {
    for (const handle of this._timers) {
      clearInterval(handle);
      clearTimeout(handle);
    }
    this._timers = [];
  }
}

class VoteSystem {
  constructor() {
    this.sessions = new Map();
    this.cooldowns = new Map();
  }

  validateMeeting(session, callerId) {
    if (this.sessions.has(session.id)) {
      throw new Error('이미 진행 중인 회의가 있습니다.');
    }

    const cooldownUntil = this.cooldowns.get(session.id) ?? 0;
    if (cooldownUntil > Date.now()) {
      const secondsLeft = Math.max(
        1,
        Math.ceil((cooldownUntil - Date.now()) / 1000),
      );
      throw new Error(
        `투표 쿨타임이 ${secondsLeft}초 남아 있습니다. 잠시 뒤 다시 시도해 주세요.`,
      );
    }
    this.cooldowns.delete(session.id);

    const caller = (session.aliveMembers ?? []).find(
      (member) => getMemberUserId(member) === callerId,
    );
    if (!caller) {
      throw new Error('생존한 플레이어만 회의를 시작할 수 있습니다.');
    }
  }

  startMeeting(session, { callerId, bodyId, reason }) {
    this.validateMeeting(session, callerId);

    const voteSession = new VoteSession({
      sessionId: session.id,
      callerId,
      bodyId,
      reason,
      settings: {
        ...session,
        totalPlayers: (session.aliveMembers ?? []).length,
      },
    });

    this.sessions.set(session.id, voteSession);
    this._startDiscussionTimer(session, voteSession);
    EventBus.emit('meeting_started', { session, voteSession });

    return voteSession;
  }

  _startDiscussionTimer(session, voteSession) {
    let remaining = voteSession.discussionTime;
    let earlyEndPending = false;

    const onEarlyEnd = () => {
      if (!earlyEndPending && remaining > 10) {
        remaining = 10;
        earlyEndPending = true;
      }
    };

    EventBus.on('discussion_early_end', onEarlyEnd);

    const handle = setInterval(() => {
      remaining -= 1;

      EventBus.emit('meeting_tick', {
        session,
        phase: VOTE_PHASE.DISCUSSION,
        remaining,
        earlyEnd: earlyEndPending,
      });

      if (remaining <= 0) {
        clearInterval(handle);
        EventBus.off('discussion_early_end', onEarlyEnd);
        this._startVotingPhase(session, voteSession);
      }
    }, 1000);

    voteSession.addTimer(handle);
  }

  _startVotingPhase(session, voteSession) {
    voteSession.applyPreVotes();
    voteSession.moveToVoting();
    EventBus.emit('voting_started', { session, voteSession });

    const alivePlayers = session.aliveMembers ?? [];
    let remaining = voteSession.voteTime;

    const handle = setInterval(() => {
      remaining -= 1;

      EventBus.emit('meeting_tick', {
        session,
        phase: VOTE_PHASE.VOTING,
        remaining,
        earlyEnd: false,
      });

      const done = voteSession.isAllVoted(alivePlayers) || remaining <= 0;
      if (done) {
        clearInterval(handle);
        this._processResult(session, voteSession);
      }
    }, 1000);

    voteSession.addTimer(handle);
  }

  submitVote(sessionId, voterId, targetId) {
    const voteSession = this.sessions.get(sessionId);
    if (!voteSession) {
      throw new Error('진행 중인 회의가 없습니다.');
    }

    if (voteSession.phase === VOTE_PHASE.DISCUSSION) {
      voteSession.submitPreVote(voterId, targetId);

      const count = voteSession.preVotes.size;
      const totalPlayers = voteSession.totalPlayers ?? 0;

      EventBus.emit('pre_vote_submitted', {
        sessionId,
        voterId,
        targetId,
        count,
        totalPlayers,
      });

      return { preVote: true, count, totalPlayers };
    }

    voteSession.submitVote(voterId, targetId);

    const count = voteSession.votes.size;
    const totalPlayers = voteSession.totalPlayers ?? 0;

    EventBus.emit('vote_submitted', {
      sessionId,
      voterId,
      targetId,
      count,
      totalPlayers,
    });

    return { preVote: false, count, totalPlayers };
  }

  _processResult(session, voteSession) {
    if (
      voteSession.phase === VOTE_PHASE.RESULT ||
      voteSession.phase === VOTE_PHASE.ENDED
    ) {
      return;
    }

    const alivePlayers = session.aliveMembers ?? [];
    const result = voteSession.tally(alivePlayers);
    const ejectedMember = result.ejected
      ? alivePlayers.find((member) => getMemberUserId(member) === result.ejected)
      : null;

    if (result.ejected && session.aliveMembers) {
      session.aliveMembers = session.aliveMembers.filter(
        (member) => getMemberUserId(member) !== result.ejected,
      );
    }

    this.cooldowns.set(session.id, Date.now() + MEETING_COOLDOWN_MS);
    voteSession.moveToResult(result);
    EventBus.emit('vote_result', {
      session,
      voteSession,
      result,
      ejected: result.ejected,
      ejectedMember,
    });

    const endTimer = setTimeout(() => {
      this._endMeeting(session, voteSession);
    }, 5000);

    voteSession.addTimer(endTimer);
  }

  _endMeeting(session, voteSession) {
    voteSession.end();
    this.sessions.delete(session.id);
    EventBus.emit('meeting_ended', { session, voteSession });
  }

  cleanupSession(sessionId) {
    const voteSession = this.sessions.get(sessionId);
    if (!voteSession) return;

    voteSession.end();
    this.sessions.delete(sessionId);
  }
}

export default new VoteSystem();
export { VOTE_PHASE };
