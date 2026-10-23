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
  if (key === null) return
  if (dock === null) globalThis.localStorage?.removeItem(key)
  else globalThis.localStorage?.setItem(key, dock)
}

export type ComposerAim =
  | { target: ComposeTarget; docked: false }
  | { target: { kind: 'session'; id: string }; docked: true }

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

export interface Targeting {
  page: string | null
  dock: string | null
  recents: string[]
}

export function reconcileTargeting(
  state: Targeting,
  page: ComposeTarget | null,
  live: readonly string[] | null,
  fallback: string | null,
): Targeting {
  const key = page === null ? null : targetKey(page)
  const own = page?.kind === 'session' ? page.id : null
  const available = (id: string | null) =>
    id !== null && (live === null || live.includes(id))
  const dock = own ?? (available(state.dock) ? state.dock : fallback)
  const kept = live === null
    ? state.recents
    : state.recents.filter((id) => live.includes(id))
  const recents = dock === null ? kept : recentTargets(kept, dock)
  return key === state.page && dock === state.dock &&
      recents.length === state.recents.length &&
      recents.every((id, index) => id === state.recents[index])
    ? state
    : { page: key, dock, recents }
}

export function pickTarget(state: Targeting, id: string): Targeting {
  return { ...state, dock: id, recents: recentTargets(state.recents, id) }
}

export function recentTargets(
  recents: readonly string[],
  target: string,
): string[] {
  return [target, ...recents.filter((id) => id !== target)].slice(0, 8)
}

export function keptRecents(scope: string | null): string[] {
  if (scope === null) return []
  const raw = globalThis.localStorage?.getItem(`wuhu:dock-recents:${scope}`)
  if (raw == null) return []
  try {
    const value: unknown = JSON.parse(raw)
    return Array.isArray(value)
      ? [...new Set(value.filter((id): id is string => typeof id === 'string'))]
        .slice(0, 8)
      : []
  } catch {
    return []
  }
}

export function keepRecents(
  scope: string | null,
  recents: readonly string[],
): void {
  if (scope !== null) {
    globalThis.localStorage?.setItem(
      `wuhu:dock-recents:${scope}`,
      JSON.stringify(recents),
    )
  }
}
