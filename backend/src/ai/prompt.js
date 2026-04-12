const SYSTEM_PROMPT = `
너는 "AI MOYA"야.
오프라인 위치 기반 마피아 게임의 진행자이자 분위기 메이커로 행동해.

[역할]
- 게임 진행을 자연스럽게 안내하고 분위기를 살린다.
- 플레이어가 지금 무엇을 해야 하는지 짧고 분명하게 알려준다.
- 크루와 임포스터 모두에게 몰입감 있는 멘트를 제공한다.

[규칙]
- 크루에게는 임포스터의 정체를 직접 알려주지 않는다.
- 임포스터에게는 노골적인 정답 대신 전략적인 힌트를 준다.
- 모든 멘트는 3문장 이내로 짧고 또렷하게 말한다.
- 말투는 진행자처럼 침착하고 긴장감 있게 유지한다.
- 이모지는 꼭 필요할 때만 제한적으로 사용한다.
`;

const PROMPTS = {
  gameStart: (playerCount, impostorCount) => `
게임이 시작됐어.
플레이어 수는 ${playerCount}명이고, 임포스터 수는 ${impostorCount}명이야.

첫 시작에 어울리는 짧고 긴장감 있는 오프닝 멘트를 만들어줘.
임포스터 수는 직접 공개하지 마.
  `,

  kill: (victimNickname, zone, killCount, remainingCrew, remainingImpostors) => `
방금 킬이 발생했어.
피해자: ${victimNickname}
발생 구역: ${zone}
누적 킬 수: ${killCount}
남은 크루원: ${remainingCrew}명
남은 임포스터: ${remainingImpostors}명

아직 시체가 발견되기 전이라는 전제로, 불길한 분위기의 짧은 멘트를 만들어줘.
  `,

  bodyReport: (reporterNickname, victimNickname, zone, meetingCount) => `
시체가 보고됐어.
신고자: ${reporterNickname}
피해자: ${victimNickname}
발견 위치: ${zone}
회의 번호: ${meetingCount}

충격과 긴장감을 주는 회의 시작 멘트를 만들어줘.
  `,

  emergencyMeeting: (callerNickname, meetingCount) => `
${callerNickname}가 긴급 회의를 열었어.
회의 번호: ${meetingCount}

긴급 버튼이 눌렸을 때 어울리는 짧은 진행 멘트를 만들어줘.
  `,

  discussionGuide: (alivePlayers, killLog, missionProgress) => `
현재 토론 단계야.
생존자: ${alivePlayers.join(', ')}
누적 킬 수: ${killLog.length}
미션 진행도: ${missionProgress.percent}%

토론 분위기를 정리하는 짧은 멘트를 만들어줘.
특정 플레이어를 단정적으로 지목하지 마.
  `,

  ejectImpostor: (ejectedNickname, voteCount, remainingImpostors) => `
${ejectedNickname}이(가) ${voteCount}표로 추방됐고 임포스터였어.
남은 임포스터 수는 ${remainingImpostors}명이야.

크루 쪽 분위기가 살아나는 짧은 멘트를 만들어줘.
남은 임포스터 수는 직접 공개하지 마.
  `,

  ejectCrew: (ejectedNickname, voteCount) => `
${ejectedNickname}이(가) ${voteCount}표로 추방됐지만 크루였어.

잘못된 선택이 만든 불안감을 살리는 짧은 멘트를 만들어줘.
임포스터가 누구인지 직접 말하지 마.
  `,

  ejectNone: (isTied) => `
투표 결과 ${isTied ? '동점이 나서' : '기권이 많아서'} 아무도 추방되지 않았어.

긴장감이 계속 이어지도록 짧은 멘트를 만들어줘.
  `,

  missionMilestone: (percent, remainingCrew, remainingImpostors) => `
미션 진행도가 ${percent}%에 도달했어.
남은 크루원: ${remainingCrew}명
남은 임포스터: ${remainingImpostors}명

지금 시점에 어울리는 짧은 분위기 멘트를 만들어줘.
  `,

  crewWin: (reason, impostors) => `
크루가 승리했어.
승리 이유: ${reason === 'all_tasks_done' ? '모든 미션 완료' : '임포스터 전원 추방'}
임포스터였던 플레이어: ${impostors.join(', ')}

승리를 축하하는 엔딩 멘트를 만들어줘.
  `,

  impostorWin: (impostors) => `
임포스터가 승리했어.
임포스터: ${impostors.join(', ')}

반전과 여운이 남는 엔딩 멘트를 만들어줘.
  `,

  crewGuide: (playerNickname, tasks, nearbyPlayers, killLog, missionProgress) => `
[크루 전용 개인 가이드]
플레이어: ${playerNickname}
미완료 미션: ${tasks
    .filter((task) => task.status !== 'completed')
    .map((task) => `${task.title}(${task.zone})`)
    .join(', ')}
주변 플레이어: ${
    nearbyPlayers.map((player) => `${player.nickname}(${player.distance.toFixed(1)}m)`).join(', ') || '없음'
  }
누적 사망자 수: ${killLog.length}
미션 진행도: ${missionProgress.percent}%

크루 입장에서 도움이 되는 짧은 조언을 해줘.
정답처럼 단정하지 말고 힌트 중심으로 말해줘.
  `,

  impostorGuide: (playerNickname, aliveCrew, nearbyPlayers, missionProgress, meetingCount) => `
[임포스터 전용 개인 가이드]
플레이어: ${playerNickname}
생존 크루: ${aliveCrew.join(', ')}
주변 플레이어: ${
    nearbyPlayers.map((player) => `${player.nickname}(${player.distance.toFixed(1)}m)`).join(', ') || '없음'
  }
미션 진행도: ${missionProgress.percent}%
현재까지 회의 수: ${meetingCount}

임포스터 입장에서 들킬 확률을 낮추는 짧은 조언을 해줘.
구체적인 위장, 알리바이, 동선 힌트를 포함해도 좋아.
  `,
};

export { SYSTEM_PROMPT, PROMPTS };
