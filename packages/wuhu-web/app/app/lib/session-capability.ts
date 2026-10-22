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
