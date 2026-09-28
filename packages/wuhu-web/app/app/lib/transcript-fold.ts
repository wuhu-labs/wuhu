import type { SessionStreamEvent } from './contract.gen'
import type { TranscriptItem } from '~/sdk/session'

export interface DirectState {
  generation: number
  items: Map<number, TranscriptItem>
  bubbles: Map<string, string>
  pendingSwaps: Map<string, string>
  materialized: Map<string, number>
}

export const initialDirectState: DirectState = {
  generation: 0,
  items: new Map(),
  bubbles: new Map(),
  pendingSwaps: new Map(),
  materialized: new Map(),
}

// Swift's synthesized enum Codable wraps the single associated value in "_0".
export function parseTranscriptItem(raw: unknown): TranscriptItem | null {
  if (typeof raw !== 'object' || raw === null) return null
  const entries = Object.entries(raw as Record<string, unknown>)
  if (entries.length !== 1) return null
  const [kind, wrapped] = entries[0]!
  if (
    ![
      'direct',
      'message',
      'notification',
      'assistant',
      'toolResult',
      'bookmark',
      'generationHead',
    ].includes(kind)
  ) return null
  const value =
    typeof wrapped === 'object' && wrapped !== null && '_0' in wrapped
      ? (wrapped as { _0: unknown })._0
      : wrapped
  return { kind, value } as TranscriptItem
}

export function isEmptyDirect(state: DirectState): boolean {
  return state.items.size === 0 && state.bubbles.size === 0
}

export function foldDirect(
  state: DirectState,
  event: SessionStreamEvent,
): DirectState {
  switch (event.kind) {
    case 'reset':
      // A reconnect resets to the same generation and replays its items by
      // position; only a new generation starts empty.
      return event.generation === state.generation ? state : {
        ...state,
        generation: event.generation,
        items: new Map(),
        materialized: new Map(),
      }
    case 'item': {
      if (event.generation !== state.generation) return state
      const item = parseTranscriptItem(event.item)
      if (!item) return state
      const items = new Map(state.items).set(event.position, item)
      if (item.kind !== 'assistant') return { ...state, items }
      // Codable UUIDs are uppercase; attempt-stream ids are lowercase.
      const entryId = item.value.id.toLowerCase()
      const attemptId = state.pendingSwaps.get(entryId)
      if (attemptId === undefined) return { ...state, items }
      const bubbles = new Map(state.bubbles)
      bubbles.delete(attemptId)
      const pendingSwaps = new Map(state.pendingSwaps)
      pendingSwaps.delete(entryId)
      const materialized = new Map(state.materialized)
        .set(attemptId, event.position)
      return { ...state, items, bubbles, pendingSwaps, materialized }
    }
    case 'started':
      // A repeated started for a known attempt means a reconnect replay: the
      // server re-sends the full accumulated text, so restart from empty.
      return {
        ...state,
        bubbles: new Map(state.bubbles).set(event.attemptId, ''),
      }
    case 'delta': {
      const bubbles = new Map(state.bubbles)
      bubbles.set(
        event.attemptId,
        (bubbles.get(event.attemptId) ?? '') + event.text,
      )
      return { ...state, bubbles }
    }
    case 'cancelled': {
      const bubbles = new Map(state.bubbles)
      bubbles.delete(event.attemptId)
      return { ...state, bubbles }
    }
    case 'materialized': {
      const pendingSwaps = new Map(state.pendingSwaps)
      pendingSwaps.set(event.entryId, event.attemptId)
      return { ...state, pendingSwaps }
    }
  }
}
