'use strict';

import { GUILD_IDS, JOB_PRIORITY } from './schema.js';

const MIN_DERIVED_POINT_GRID = 5;

export function buildGuilds(members, teamDefinitions) {
  const guildIds = teamDefinitions.map((team) => team.teamId);
  const guilds = {};
  const playerGuildMap = new Map();

  teamDefinitions.forEach((team) => {
    const guildId = team.teamId;
    guilds[guildId] = {
      guildId,
      displayName: team.displayName ?? guildDisplayName(guildId),
      color: team.color ?? guildColor(guildId),
      memberIds: [],
      guildMasterId: null,
      score: 0,
      spawnZone: null,
    };
  });

  const queuedMembers = [...members].sort(() => Math.random() - 0.5);

  queuedMembers.forEach((member) => {
    const preferredGuildId = guildIds.includes(member.team_id) ? member.team_id : null;
    if (preferredGuildId) {
      guilds[preferredGuildId].memberIds.push(member.user_id);
      playerGuildMap.set(member.user_id, preferredGuildId);
      return;
    }

    const targetGuildId = guildIds.reduce((bestGuildId, guildId) => {
      if (!bestGuildId) {
        return guildId;
      }

      return guilds[guildId].memberIds.length < guilds[bestGuildId].memberIds.length
        ? guildId
        : bestGuildId;
    }, null);

    guilds[targetGuildId].memberIds.push(member.user_id);
    playerGuildMap.set(member.user_id, targetGuildId);
  });

  guildIds.forEach((guildId) => {
    const guild = guilds[guildId];
    guild.guildMasterId = guild.memberIds[0] ?? null;
  });

  return { guilds, playerGuildMap };
}

export function assignJobs(guilds) {
  const playerJobMap = new Map();

  Object.values(guilds).forEach((guild) => {
    guild.memberIds.forEach((userId, index) => {
      const job = JOB_PRIORITY[index % JOB_PRIORITY.length] ?? 'warrior';
      playerJobMap.set(userId, job);
    });
  });

  return playerJobMap;
}

export function buildControlPoints(count, locations = []) {
  return Array.from({ length: count }, (_, index) => ({
    id: `cp_${index + 1}`,
    displayName: `점령지 ${index + 1}`,
    capturedBy: null,
    captureProgress: 0,
    capturingGuild: null,
    captureStartedAt: null,
    lastCaptureAt: null,
    blockadedBy: null,
    blockadeExpiresAt: null,
    location: locations[index] ?? null,
    captureParticipantUserIds: [],
  }));
}

export function buildDungeons() {
  return [
    {
      id: 'dungeon_main',
      displayName: 'Main Dungeon',
      status: 'open',
      artifact: {
        id: 'artifact_main',
        heldBy: null,
        location: null,
      },
      openedAt: Date.now(),
      clearedAt: null,
    },
  ];
}

export function buildInitialPluginState(members, config, session = null) {
  const configuredTeams = resolveTeamDefinitions(config);
  const teamCount = configuredTeams.length;
  const controlPointCount = config.controlPointCount ?? 5;
  const playableArea = normalizeGeoList(session?.playable_area);
  const controlPointLocations = resolveControlPointLocations(session, config, controlPointCount);
  const spawnZones = normalizeSpawnZones(config?.spawnZones, configuredTeams);

  const { guilds, playerGuildMap } = buildGuilds(members, configuredTeams);
  const playerJobMap = assignJobs(guilds);
  const controlPoints = buildControlPoints(controlPointCount, controlPointLocations);
  const dungeons = buildDungeons();

  if (controlPoints.some((cp) => !cp.location)) {
    throw new Error('CONTROL_POINT_LOCATIONS_REQUIRED');
  }

  spawnZones.forEach((zone) => {
    if (guilds[zone.teamId]) {
      guilds[zone.teamId].spawnZone = zone;
    }
  });

  const playerStates = {};
  members.forEach((member) => {
    const userId = member.user_id;
    const guildId = playerGuildMap.get(userId) ?? 'unknown';
    const job = playerJobMap.get(userId) ?? 'warrior';
    const guild = guilds[guildId];
    playerStates[userId] = {
      userId,
      nickname: member.nickname ?? userId,
      guildId,
      job,
      isGuildMaster: guild?.guildMasterId === userId,
      isAlive: true,
      reviveAttempts: 0,
      skillUsedAt: {},
      hp: 100,
      remainingLives: job === 'warrior' ? 2 : 1,
      captureZone: null,
      inDuel: false,
      duelExpiresAt: null,
      shields: [],
      buffedUntil: null,
      revealUntil: null,
      trackedTargetUserId: null,
      executionArmedUntil: null,
      dungeonEnteredAt: null,
      spawnZoneTeamId: guildId,
    };
  });

  return {
    guilds,
    controlPoints,
    dungeons,
    playableArea,
    spawnZones,
    playerStates,
    captureIntents: {},
    eliminatedPlayerIds: [],
    pendingVictory: null,
    winCondition: null,
    _config: config,
  };
}

function resolveControlPointLocations(session, config, count) {
  const explicitPoints = normalizeGeoList(config?.controlPoints);
  if (explicitPoints.length >= count) {
    return explicitPoints.slice(0, count);
  }

  const derivedPoints = deriveControlPointLocations(
    normalizeGeoList(session?.playable_area),
    count,
  );

  return dedupeGeoPoints([...explicitPoints, ...derivedPoints]).slice(0, count);
}

function resolveTeamDefinitions(config) {
  const configuredTeams = Array.isArray(config?.teams) ? config.teams : [];
  if (configuredTeams.length > 0) {
    return configuredTeams
      .map((team, index) => ({
        teamId: team?.teamId ?? GUILD_IDS[index],
        displayName: team?.displayName ?? guildDisplayName(team?.teamId ?? GUILD_IDS[index]),
        color: team?.color ?? guildColor(team?.teamId ?? GUILD_IDS[index]),
      }))
      .filter((team) => team.teamId);
  }

  const teamCount = Math.max(1, Math.min(config?.teamCount ?? 3, GUILD_IDS.length));
  return GUILD_IDS.slice(0, teamCount).map((teamId) => ({
    teamId,
    displayName: guildDisplayName(teamId),
    color: guildColor(teamId),
  }));
}

function normalizeSpawnZones(spawnZones, teamDefinitions) {
  if (!Array.isArray(spawnZones) || spawnZones.length === 0) {
    return [];
  }

  return teamDefinitions
    .map((team) => {
      const rawZone = spawnZones.find((zone) => zone?.teamId === team.teamId);
      const polygonPoints = normalizeGeoList(rawZone?.polygonPoints);
      if (polygonPoints.length < 3) {
        return null;
      }

      return {
        teamId: team.teamId,
        displayName: rawZone?.displayName ?? team.displayName,
        color: rawZone?.color ?? team.color,
        polygonPoints,
      };
    })
    .filter(Boolean);
}

function deriveControlPointLocations(playableArea, count) {
  if (playableArea.length < 3 || count <= 0) {
    return [];
  }

  const bounds = computeBounds(playableArea);
  if (!bounds) {
    return [];
  }

  const gridSize = Math.max(MIN_DERIVED_POINT_GRID, Math.ceil(Math.sqrt(count)) * 3);
  const candidates = [];

  for (let row = 0; row < gridSize; row += 1) {
    for (let column = 0; column < gridSize; column += 1) {
      const lat = bounds.minLat + ((row + 0.5) / gridSize) * (bounds.maxLat - bounds.minLat);
      const lng = bounds.minLng + ((column + 0.5) / gridSize) * (bounds.maxLng - bounds.minLng);
      const candidate = { lat, lng };
      if (pointInPolygon(candidate, playableArea)) {
        candidates.push(candidate);
      }
    }
  }

  const centroid = averagePoint(playableArea);
  if (centroid && pointInPolygon(centroid, playableArea)) {
    candidates.push(centroid);
  }

  playableArea.forEach((point, index) => {
    const nextPoint = playableArea[(index + 1) % playableArea.length];
    candidates.push({
      lat: (point.lat + nextPoint.lat) / 2,
      lng: (point.lng + nextPoint.lng) / 2,
    });
    candidates.push({
      lat: centroid ? point.lat * 0.65 + centroid.lat * 0.35 : point.lat,
      lng: centroid ? point.lng * 0.65 + centroid.lng * 0.35 : point.lng,
    });
  });

  return pickSpreadPoints(
    candidates.filter((candidate) => pointInPolygon(candidate, playableArea)),
    count,
  );
}

function pickSpreadPoints(candidates, count) {
  const unique = dedupeGeoPoints(candidates);
  if (unique.length <= count) {
    return unique;
  }

  const center = averagePoint(unique) ?? unique[0];
  const chosen = [closestPointTo(unique, center)];
  const remaining = unique.filter((point) => !sameGeoPoint(point, chosen[0]));

  while (chosen.length < count && remaining.length > 0) {
    let bestIndex = 0;
    let bestScore = -1;

    remaining.forEach((candidate, index) => {
      const score = Math.min(...chosen.map((picked) => distanceSquared(candidate, picked)));
      if (score > bestScore) {
        bestScore = score;
        bestIndex = index;
      }
    });

    chosen.push(remaining.splice(bestIndex, 1)[0]);
  }

  return chosen;
}

function closestPointTo(points, target) {
  return points.reduce((best, point) => (
    distanceSquared(point, target) < distanceSquared(best, target) ? point : best
  ), points[0]);
}

function distanceSquared(a, b) {
  return ((a.lat - b.lat) ** 2) + ((a.lng - b.lng) ** 2);
}

function computeBounds(points) {
  if (points.length === 0) {
    return null;
  }

  return points.reduce((bounds, point) => ({
    minLat: Math.min(bounds.minLat, point.lat),
    maxLat: Math.max(bounds.maxLat, point.lat),
    minLng: Math.min(bounds.minLng, point.lng),
    maxLng: Math.max(bounds.maxLng, point.lng),
  }), {
    minLat: points[0].lat,
    maxLat: points[0].lat,
    minLng: points[0].lng,
    maxLng: points[0].lng,
  });
}

function pointInPolygon(point, polygon) {
  let inside = false;

  for (let i = 0, j = polygon.length - 1; i < polygon.length; j = i, i += 1) {
    const xi = polygon[i].lng;
    const yi = polygon[i].lat;
    const xj = polygon[j].lng;
    const yj = polygon[j].lat;

    const intersects = ((yi > point.lat) !== (yj > point.lat))
      && (point.lng < ((xj - xi) * (point.lat - yi)) / ((yj - yi) || Number.EPSILON) + xi);

    if (intersects) {
      inside = !inside;
    }
  }

  return inside;
}

function averagePoint(points) {
  if (points.length === 0) {
    return null;
  }

  const total = points.reduce((acc, point) => ({
    lat: acc.lat + point.lat,
    lng: acc.lng + point.lng,
  }), { lat: 0, lng: 0 });

  return {
    lat: total.lat / points.length,
    lng: total.lng / points.length,
  };
}

function dedupeGeoPoints(points) {
  const seen = new Set();
  const result = [];

  points.forEach((point) => {
    const normalized = normalizeGeoPoint(point);
    if (!normalized) {
      return;
    }

    const key = `${normalized.lat.toFixed(6)}:${normalized.lng.toFixed(6)}`;
    if (seen.has(key)) {
      return;
    }

    seen.add(key);
    result.push(normalized);
  });

  return result;
}

function normalizeGeoList(points) {
  if (!Array.isArray(points)) {
    return [];
  }

  return points
    .map(normalizeGeoPoint)
    .filter(Boolean);
}

function normalizeGeoPoint(point) {
  const lat = Number(point?.lat ?? point?.latitude);
  const lng = Number(point?.lng ?? point?.longitude ?? point?.lon);

  if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
    return null;
  }
  if (lat < -90 || lat > 90 || lng < -180 || lng > 180) {
    return null;
  }

  return { lat, lng };
}

function sameGeoPoint(a, b) {
  return a.lat === b.lat && a.lng === b.lng;
}

function guildDisplayName(guildId) {
  const names = {
    guild_alpha: '붉은 길드',
    guild_beta: '푸른 길드',
    guild_gamma: '초록 길드',
    guild_delta: '황금 길드',
  };
  return names[guildId] ?? guildId;
}

function guildColor(guildId) {
  const colors = {
    guild_alpha: '#DC2626',
    guild_beta: '#2563EB',
    guild_gamma: '#16A34A',
    guild_delta: '#D97706',
  };
  return colors[guildId] ?? '#9CA3AF';
}
