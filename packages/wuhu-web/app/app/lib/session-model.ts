import type { SessionKind } from './session-create.ts'
import type { SessionRoute } from './model-route.ts'
export interface SessionSummary {
  id: string
  group: string
  title: string
  hold: string
  work: string
  runState: SessionRunState
  lifecycle: string
  kind: SessionKind
  parent: string | null
  // Messages in its box the viewer has not read.
  unread: number
  // Absent on a direct session and on a server without route tables.
  route?: SessionRoute | null
}

export type SessionRunState = 'inference' | 'tool' | 'no_run' | 'unknown'

export function sessionRunState(value: unknown): SessionRunState {
  switch (value) {
    case 'inference':
    case 'tool':
    case 'no_run':
      return value
    default:
      return 'unknown'
  }
}

export function isSessionWorking(
  session: Pick<SessionSummary, 'runState'>,
): boolean {
  switch (session.runState) {
    case 'inference':
    case 'tool':
      return true
    case 'no_run':
    case 'unknown':
      return false
  }
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
  createdAt: string
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

export function executorSpec(config: string): ExecutorSpec {
  return JSON.parse(config) as ExecutorSpec
}

export function executorLabel(executor: string, config: string): string {
  if (executor !== 'kernel') return executor
  const spec = executorSpec(config)
  return spec.modelGroup ?? `${spec.provider}/${spec.model}`
}

export function sessionKind(value: unknown): SessionKind {
  if (value !== 'agent' && value !== 'task') {
    throw new Error(`Unknown session kind: ${value}`)
  }
  return value
}
