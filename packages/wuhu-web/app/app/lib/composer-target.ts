import type { SessionView } from './links.ts'
import { canCompose, type SessionCapability } from './session-capability.ts'
import type { SpaceDestination } from './space-url.ts'

export type ComposeTarget =
  | { kind: 'session'; id: string }
  | { kind: 'conversation'; id: string }

export function targetKey(target: ComposeTarget): string {
  return `${target.kind}:${target.id}`
}

// The page's own input: an agent's box, or a conversation the reader may post
// in. A task, a transcript, an unknown session and every other page have none.
export function pageTarget(
  destination: SpaceDestination | null,
  view: SessionView | null,
  capability: SessionCapability,
): ComposeTarget | null {
  if (!canCompose(capability)) return null
  if (destination?.kind === 'conversation') return destination
  if (destination?.kind === 'session' && view === null) return destination
  return null
}

// The desktop dock aims at the last agent box the reader opened, and only an
// agent box moves it.
export function dockAfter(
  dock: string | null,
  page: ComposeTarget | null,
): string | null {
  return page?.kind === 'session' ? page.id : dock
}

export type ComposerAim =
  | { target: ComposeTarget; docked: false }
  | { target: { kind: 'session'; id: string }; docked: true }

export function composerAim({ page, dock, dockCapability, compact }: {
  page: ComposeTarget | null
  dock: string | null
  dockCapability: SessionCapability
  compact: boolean
}): ComposerAim | null {
  if (page !== null) return { target: page, docked: false }
  if (compact || dock === null || !canCompose(dockCapability)) return null
  return { target: { kind: 'session', id: dock }, docked: true }
}
