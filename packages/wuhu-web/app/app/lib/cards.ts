import { isSessionWorking, type SessionSummary } from './session-model.ts'

// The sidebar is cards of two levels: a top-level item and its direct
// children. Deeper descendants are not drawn.
export interface Parented {
  id: string
  parent: string | null
}

export interface CardGroup<T> {
  item: T
  children: T[]
}

// An item whose parent is not in the list is top-level, so filtering a
// parent out never hides its children.
export function cardGroups<T extends Parented>(
  items: readonly T[],
): CardGroup<T>[] {
  const ids = new Set(items.map((item) => item.id))
  const roots = items.filter((item) =>
    item.parent == null || !ids.has(item.parent)
  )
  return roots.map((item) => ({
    item,
    children: items.filter((child) => child.parent === item.id),
  }))
}

// Oldest first: activity never moves a card under the pointer, and a
// newcomer joins at the end.
export function inCreationOrder<T extends { createdAt: string }>(
  items: readonly T[],
): T[] {
  return [...items].sort((a, b) => a.createdAt.localeCompare(b.createdAt))
}

export type StatusTone = 'working' | 'not' | 'trouble'

// A session's status line: working in green, trouble in red, and otherwise
// the grey "not working".
export function sessionStatusLine(
  session: Pick<SessionSummary, 'hold' | 'work' | 'route' | 'runState'>,
): { tone: StatusTone; label: string } {
  if (session.hold === 'errored' || session.work === 'errored') {
    return { tone: 'trouble', label: 'errored' }
  }
  if (session.hold === 'interrupted') {
    return { tone: 'trouble', label: 'interrupted' }
  }
  if (session.route?.phase === 'waiting') {
    return { tone: 'not', label: 'waiting on model' }
  }
  return isSessionWorking(session)
    ? { tone: 'working', label: 'working' }
    : { tone: 'not', label: 'not working' }
}
