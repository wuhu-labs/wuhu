import type { SessionKind } from './session-create.ts'

export type SessionCapability =
  | { kind: 'unknown' }
  | { kind: 'agent' }
  | { kind: 'task' }
  | { kind: 'archived' }
  | { kind: 'conversation'; allowed: boolean }

export function sessionCapability(
  record: { kind: SessionKind; lifecycle: string } | null,
): SessionCapability {
  if (record === null) return { kind: 'unknown' }
  if (record.lifecycle === 'archived') return { kind: 'archived' }
  return { kind: record.kind }
}

export function canCompose(capability: SessionCapability): boolean {
  return capability.kind === 'agent' ||
    (capability.kind === 'conversation' && capability.allowed)
}

export function canManageSession(capability: SessionCapability): boolean {
  return capability.kind === 'agent' || capability.kind === 'task'
}

export type SessionAction = 'compact' | 'restart' | 'archive' | 'unarchive'

export function sessionActions(capability: SessionCapability): SessionAction[] {
  if (canManageSession(capability)) return ['compact', 'restart', 'archive']
  return capability.kind === 'archived' ? ['unarchive'] : []
}
