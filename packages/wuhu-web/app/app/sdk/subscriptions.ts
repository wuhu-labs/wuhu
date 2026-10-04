import type { SpaceClient } from './client'
import type {
  ConversationMessagePayload,
  MutationEvent,
  QueryOutput,
  SessionStreamEvent,
} from '~/lib/contract.gen'
import type { Subscription } from './observe'
import { api, inGroup } from './http'
import type { HistoryPage } from './history-window'
import { normalizeSQL } from '~/lib/shell-sdk/open-cache.js'

// Per entry, so one long history never takes its kind's whole budget.
export const conversationBytes = 1_000_000
export const transcriptBytes = 2_000_000

// Each stream acts in one group; its kept events are that group's.
export interface GroupSubscription<Event> extends Subscription<Event> {
  readonly group: string
}

export function globSubscription(
  client: SpaceClient,
  glob: string,
  from: number,
): GroupSubscription<MutationEvent> {
  return {
    group: client.group,
    from,
    url: (cursor) => client.observeURL(glob, cursor ?? from),
    cursorOf: (event) => event.rev,
  }
}

export function conversationSubscription(
  conversation: string,
  group: string,
): GroupSubscription<ConversationMessagePayload> {
  return {
    group,
    from: 0,
    history: {
      async page(before, _generation, signal) {
        const query = before === null ? 'tail=100' : `tail=100&before=${before}`
        const page = await api<ConversationPage>(
          `/v1/conversation/${conversation}/messages?${query}&paged=true`,
          { headers: inGroup(group), signal },
        )
        return {
          ...page,
          generation: 0,
          historyEpoch: null,
          headPosition: page.headPosition ?? 0,
          entries: page.messages.map((event) => ({ position: event.n, event })),
          origins: [],
        }
      },
      url: (_generation, position) =>
        `/v1/conversation/${conversation}/observe?after=${position}`,
      position: (event) => event.n,
      generation: () => null,
      reset: () => null,
      isReset: () => false,
    },
    url: (cursor) =>
      `/v1/conversation/${conversation}/observe?after=${cursor ?? 0}`,
    cursorOf: (message) => message.n,
    retention: {
      kind: 'conversation',
      key: conversation,
      retain: (kept, message) => {
        kept.push(message)
        return kept
      },
      maxBytes: conversationBytes,
    },
  }
}

export function sqlSubscription(
  sql: string,
  group: string,
): GroupSubscription<QueryOutput> {
  // Not URLSearchParams: it form-encodes spaces as "+", which the server's
  // query parser keeps literal.
  const url = `/v1/observe?sql=${encodeURIComponent(sql)}&throttleMs=150`
  return {
    group,
    from: null,
    url: () => url,
    cursorOf: () => null,
    retention: {
      kind: 'query',
      key: normalizeSQL(sql),
      retain: (_, output) => [output],
    },
  }
}

// A table path is a SQL identifier, so a quote inside it is doubled rather
// than escaped.
export function tableSubscription(
  path: string,
  group: string,
): GroupSubscription<QueryOutput> {
  return sqlSubscription(
    `SELECT * FROM "${path.replaceAll('"', '""')}"`,
    group,
  )
}

export function directSubscription(
  session: string,
  group: string,
): GroupSubscription<SessionStreamEvent> {
  const url = `/v1/session/${session}/direct`
  const item = (
    generation: number,
    entry: PositionedItem,
  ): SessionStreamEvent => ({ kind: 'item', generation, ...entry })
  return {
    group,
    from: null,
    history: {
      async page(
        before,
        generation,
        signal,
        historyEpoch,
      ): Promise<HistoryPage<SessionStreamEvent>> {
        const query = before === null
          ? ''
          : `&generation=${generation}&before=${before}${
            historyEpoch === null
              ? ''
              : `&epoch=${encodeURIComponent(historyEpoch)}`
          }`
        const page = await api<TranscriptPage>(
          `/v1/session/${session}/transcript/page?limit=200${query}`,
          { headers: inGroup(group), signal },
        )
        const entries = (rows: PositionedItem[]) =>
          rows.map((entry) => ({
            position: entry.position,
            event: item(page.generation, entry),
          }))
        return {
          ...page,
          historyEpoch: page.historyEpoch ?? null,
          headPosition: page.headPosition ?? -1,
          entries: entries(page.entries),
          origins: entries(page.origins),
        }
      },
      url: (generation, position, historyEpoch) =>
        `${url}?paged=true&generation=${generation}&position=${position}${
          historyEpoch === null
            ? ''
            : `&epoch=${encodeURIComponent(historyEpoch)}`
        }`,
      position: (event) => event.kind === 'item' ? event.position : null,
      generation: (event) =>
        event.kind === 'item' || event.kind === 'reset'
          ? event.generation
          : null,
      reset: (generation) => ({ kind: 'reset', generation }),
      isReset: (event) => event.kind === 'reset',
    },
    url: () => url,
    cursorOf: (event) => event.kind === 'item' ? event.position : null,
    retention: {
      kind: 'transcript',
      key: session,
      retain: retainTranscript,
      maxBytes: transcriptBytes,
      pinned: 1,
    },
  }
}

function retainTranscript(
  kept: SessionStreamEvent[],
  event: SessionStreamEvent,
): SessionStreamEvent[] {
  if (event.kind === 'reset') return [event]
  if (event.kind !== 'item') return kept
  kept.push(event)
  return kept
}

interface ConversationPage {
  messages: ConversationMessagePayload[]
  before: number | null
  hasEarlier: boolean
  headPosition: number | null
}

interface PositionedItem {
  position: number
  item: Extract<SessionStreamEvent, { kind: 'item' }>['item']
}

interface TranscriptPage {
  generation: number
  historyEpoch?: string | null
  entries: PositionedItem[]
  origins: PositionedItem[]
  before: number | null
  hasEarlier: boolean
  headPosition?: number | null
}
