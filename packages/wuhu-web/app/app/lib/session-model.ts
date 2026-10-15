import type { SessionKind } from './session-create.ts'
import type { SessionRoute } from './model-route.ts'
export interface SessionSummary {
  id: string
  group: string
  title: string
  hold: string
  work: string
  lifecycle: string
  kind: SessionKind
  parent: string | null
  unread: boolean
  // Absent on a direct session and on a server without route tables.
  route?: SessionRoute | null
}

export interface ExecutorSpec {
  provider?: string
  model?: string
  effort?: string
  modelGroup?: string
}

export interface SessionRecord extends SessionSummary {
  executorLabel: string
  spec: ExecutorSpec
  lastActivityAt: string
  errorMessage: string | null
  createdBy: string
}

export type SessionLookup<T> =
  | { kind: 'loading' }
  | { kind: 'missing' }
  | { kind: 'found'; record: T }

// A session this tab just created is still loading, not missing, until the
// roster catches up with it.
export function lookupSession<T extends { id: string }>(
  sessions: readonly T[] | null,
  id: string,
  created: boolean,
): SessionLookup<T> {
  const record = sessions?.find((session) => session.id === id)
  if (record != null) return { kind: 'found', record }
  return sessions === null || created
    ? { kind: 'loading' }
    : { kind: 'missing' }
}

// The one word a session earns beyond its identity: only trouble and motion get
// named, a session in its ordinary live state stays quiet.
export function sessionStatus(
  session: Pick<SessionSummary, 'hold' | 'work' | 'route'>,
): { label: string; tone: 'rose' | 'amber' | 'neutral' } | null {
  if (session.hold === 'errored' || session.work === 'errored') {
    return { label: 'errored', tone: 'rose' }
  }
  if (session.route?.phase === 'waiting') {
    return { label: 'waiting on model', tone: 'amber' }
  }
  if (session.work === 'working' || session.work === 'has_work') {
    return { label: 'working', tone: 'amber' }
  }
  if (session.hold === 'interrupted') {
    return { label: 'interrupted', tone: 'neutral' }
  }
  return null
}

export function executorSpec(config: string): ExecutorSpec {
  return JSON.parse(config) as ExecutorSpec
}

export function executorLabel(executor: string, config: string): string {
  if (executor !== 'kernel') return executor
  const spec = executorSpec(config)
  return spec.modelGroup ?? `${spec.provider}/${spec.model}`
}

// A group session names its group and the member it runs on. Its stored
// executor config is the member's concrete provider/model, so the label comes
// from the route, not the config.
export function rosterModelLabel(
  session: Pick<SessionRecord, 'executorLabel' | 'route'>,
): string {
  return session.route == null
    ? session.executorLabel
    : `${session.route.group} → ${session.route.member}`
}

export function sessionKind(value: unknown): SessionKind {
  if (value !== 'agent' && value !== 'task') {
    throw new Error(`Unknown session kind: ${value}`)
  }
  return value
}
