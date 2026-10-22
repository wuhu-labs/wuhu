import { canCompose, type SessionCapability } from './session-capability.ts'
import type { SpaceDestination } from './space-url.ts'

export type ComposeTarget =
  | { kind: 'session'; id: string }
  | { kind: 'conversation'; id: string }

export function targetKey(target: ComposeTarget): string {
  return `${target.kind}:${target.id}`
}

// The page's own input: an agent's box, or a conversation the reader may post
// in. A task, an unknown session and every other page have none.
export function pageTarget(
  destination: SpaceDestination | null,
  capability: SessionCapability,
): ComposeTarget | null {
  if (!canCompose(capability)) return null
  if (destination?.kind === 'conversation') return destination
  if (destination?.kind === 'session') return destination
  return null
}

// The dock, kept per space and browser.
function dockKey(scope: string | null): string | null {
  return scope === null ? null : `wuhu:dock:${scope}`
}

export function keptDock(scope: string | null): string | null {
  const key = dockKey(scope)
  return key === null ? null : globalThis.localStorage?.getItem(key) ?? null
}

export function keepDock(scope: string | null, dock: string | null): void {
  const key = dockKey(scope)
  if (key === null || dock === null) return
  globalThis.localStorage?.setItem(key, dock)
}

// The dock aims at the last agent box the reader opened, and only an agent box
// moves it.
export function dockAfter(
  dock: string | null,
  page: ComposeTarget | null,
): string | null {
  return page?.kind === 'session' ? page.id : dock
}

export type ComposerAim =
  | { target: ComposeTarget; docked: false }
  | { target: { kind: 'session'; id: string }; docked: true }

// A session or conversation page posts to itself or has no composer; any other
// page asks the docked agent about itself.
export function composerAim({ destination, page, dock }: {
  destination: SpaceDestination | null
  page: ComposeTarget | null
  dock: string | null
}): ComposerAim | null {
  if (destination?.kind === 'session' || destination?.kind === 'conversation') {
    return page === null ? null : { target: page, docked: false }
  }
  return dock === null
    ? null
    : { target: { kind: 'session', id: dock }, docked: true }
}
