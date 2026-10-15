import type { QueryOutput, SessionModelRouteOutput } from './contract.gen.ts'

// The group member a session runs on. `reason` is the latest placement
// decision's reason as the server wrote it; unknown reasons render verbatim.
export interface SessionRoute {
  group: string
  member: string
  phase: string
  epoch: string
  reason: string | null
  previousMember: string | null
  // Changes whenever the server rewrites the open failure without moving the
  // route; readers refetch the failure on a change.
  failureRevision: string | null
}

export interface RouteFailure {
  reason: string
  source: string | null
  code: string | null
  deadline: Date | null
  retryAt: Date | null
}

export type RouteStage =
  | 'pinned'
  | 'waiting'
  | 'blocked'
  | 'recovered'
  | 'switched'

export interface RouteNote {
  stage: RouteStage
  text: string
  tone: 'rose' | 'amber' | 'neutral' | 'live'
}

// `previous_member` is the member of the decision before the latest one, and
// only when that decision placed the same group.
export const sessionRoutesSQL =
  `SELECT r.session_id, r.group_id, r.member_id, r.phase, r.route_epoch,
  (SELECT h.reason FROM session_model_route_history h WHERE h.session_id = r.session_id ORDER BY h.decision_id DESC LIMIT 1) AS reason,
  (SELECT h.member_id FROM session_model_route_history h WHERE h.session_id = r.session_id AND h.group_id = r.group_id
    AND h.decision_id < (SELECT MAX(l.decision_id) FROM session_model_route_history l WHERE l.session_id = r.session_id)
    ORDER BY h.decision_id DESC LIMIT 1) AS previous_member,
  json_extract(r.payload, '$.failure') AS failure_revision
FROM session_model_routes r
WHERE r.group_id IS NOT NULL AND r.member_id IS NOT NULL`

export function withRoutes<Row extends { id: string }>(
  rows: Row[] | null,
  routes: ReadonlyMap<string, SessionRoute>,
): (Row & { route?: SessionRoute })[] | null {
  return rows?.map((row) => {
    const route = routes.get(row.id)
    return route == null ? row : { ...row, route }
  }) ?? null
}

function text(value: unknown): string | null {
  return typeof value === 'string' ? value : null
}

export function routeRows(output: QueryOutput): Map<string, SessionRoute> {
  const routes = new Map<string, SessionRoute>()
  for (const row of output.rows) {
    const [id, group, member] = [text(row[0]), text(row[1]), text(row[2])]
    if (id == null || group == null || member == null) continue
    routes.set(id, {
      group,
      member,
      phase: text(row[3]) ?? '',
      epoch: text(row[4]) ?? '',
      reason: text(row[5]),
      previousMember: text(row[6]),
      failureRevision: text(row[7]),
    })
  }
  return routes
}

function date(value: unknown): Date | null {
  const raw = text(value)
  if (raw == null) return null
  const parsed = new Date(raw)
  return Number.isNaN(parsed.getTime()) ? null : parsed
}

export function routeFailureOf(
  output: SessionModelRouteOutput,
): RouteFailure | null {
  const route = output.route as Record<string, unknown> | null | undefined
  const failure = route?.failure as Record<string, unknown> | null | undefined
  const reason = text(failure?.reason)
  if (failure == null || reason == null) return null
  return {
    reason,
    source: text(failure.source),
    code: text(failure.code),
    deadline: date(failure.deadline),
    retryAt: date(failure.retryAt),
  }
}

function cause(reason: string | null): string {
  switch (reason) {
    case 'quota':
      return 'quota exhaustion'
    case 'authentication':
      return 'an authentication failure'
    case 'upstreamOutage':
      return 'an upstream outage'
    case null:
      return 'a refusal'
    default:
      return reason
  }
}

function shortTime(when: Date): string {
  return when.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
}

const pinReasons = new Set(['create', 'startOver', 'compaction'])

// A waiting route turns blocked once its switch deadline passes with the
// session still waiting: no other member could take it. `recovered` is live
// only; nothing records a route that stopped waiting without moving. A reason
// this client does not know renders verbatim. Beside a failure line, a
// blocked note leaves the cause to that line.
export function routeNote(
  route: SessionRoute,
  failure: RouteFailure | null,
  recovered: boolean,
  now: Date,
  time: (when: Date) => string = shortTime,
  failureLine = false,
): RouteNote {
  const placed = `${route.group} → ${route.member}`
  if (route.phase === 'waiting') {
    const deadline = failure?.deadline ?? null
    if (deadline != null && now >= deadline) {
      const signIn = failure?.reason === 'authentication' ||
        failure?.source === 'credentialRefresh'
      const next = signIn
        ? ' · sign-in required'
        : failure?.retryAt
        ? ` · next retry ${time(failure.retryAt)}`
        : ''
      return {
        stage: 'blocked',
        text: `${route.group} blocked on ${route.member}${
          failureLine ? '' : `: ${cause(failure?.reason ?? null)}`
        }${next}`,
        tone: 'rose',
      }
    }
    return {
      stage: 'waiting',
      text: `Waiting on ${route.member}${
        deadline == null ? '' : ` · switch eligible ${time(deadline)}`
      }`,
      tone: 'amber',
    }
  }
  if (recovered) {
    return { stage: 'recovered', text: `${placed} · recovered`, tone: 'live' }
  }
  const reason = route.reason
  if (reason == null || pinReasons.has(reason)) {
    return { stage: 'pinned', text: placed, tone: 'neutral' }
  }
  if (reason.startsWith('lastResort:')) {
    const from = route.previousMember != null &&
        route.previousMember !== route.member
      ? ` from ${route.previousMember}`
      : ''
    return {
      stage: 'switched',
      text: `${placed} · switched${from} after ${
        cause(reason.slice('lastResort:'.length))
      }`,
      tone: 'neutral',
    }
  }
  return { stage: 'pinned', text: `${placed} · ${reason}`, tone: 'neutral' }
}

// A route that leaves waiting on the same pin has recovered; it stays
// recovered until the route moves or waits again.
export function stillRecovered(
  before: SessionRoute | null,
  after: SessionRoute | null,
  recovered: boolean,
): boolean {
  if (after == null || after.phase === 'waiting') return false
  const same = before != null && before.group === after.group &&
    before.epoch === after.epoch
  if (!same) return false
  return before.phase === 'waiting' || recovered
}
