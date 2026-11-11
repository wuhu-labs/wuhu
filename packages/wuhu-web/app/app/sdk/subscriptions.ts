import type { SpaceClient } from './client'
import type {
  ConversationMessagePayload,
  QueryOutput,
  RevisionEvents,
  SessionLineEvent,
  SessionLinePayload,
  SessionLinesPageOutput,
} from '~/lib/contract.gen'
import type { Subscription } from './observe'
import { api, inGroup } from './http'
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
  from: number | null,
): GroupSubscription<RevisionEvents> {
  return {
    group: client.group,
    from,
    url: (cursor) => client.observeURL(glob, cursor ?? from, true),
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
  // Bound to the statement's `?` placeholders.
  params?: readonly (string | number | null)[],
): GroupSubscription<QueryOutput> {
  // Not URLSearchParams: it form-encodes spaces as "+", which the server's
  // query parser keeps literal.
  const bound = params == null
    ? ''
    : `&params=${encodeURIComponent(JSON.stringify(params))}`
  const url = `/v1/observe?sql=${
    encodeURIComponent(sql)
  }${bound}&throttleMs=150`
  return {
    group,
    from: null,
    url: () => url,
    cursorOf: () => null,
    retention: {
      kind: 'query',
      key: normalizeSQL(sql) + bound,
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

export function linesSubscription(
  session: string,
  group: string,
): GroupSubscription<SessionLineEvent> {
  const line = (
    generation: number,
    line: SessionLinePayload,
  ): SessionLineEvent => ({ kind: 'line', generation, line })
  return {
    group,
    from: null,
    history: {
      async page(before, generation, signal) {
        const query = before === null
          ? ''
          : `&generation=${generation}&before=${before}`
        const page = await api<SessionLinesPageOutput>(
          `/v1/session/${session}/lines/page?limit=200${query}`,
          { headers: inGroup(group), signal },
        )
        return {
          generation: page.generation,
          historyEpoch: null,
          entries: page.lines.map((entry) => ({
            position: entry.position,
            event: line(page.generation, entry),
          })),
          origins: [],
          before: page.lines[0]?.position ?? null,
          hasEarlier: page.hasEarlier,
          headPosition: page.lines.at(-1)?.position ?? -1,
        }
      },
      url: (generation, position) =>
        `/v1/session/${session}/lines?generation=${generation}&after=${position}`,
      position: (event) => event.kind === 'line' ? event.line.position : null,
      // A prompt line is written late, below the head, and is resent on
      // every catch-up.
      pinned: (event) => event.kind === 'line' && event.line.prompt,
      generation: (event) => event.generation,
      reset: (generation) => ({ kind: 'reset', generation }),
      isReset: (event) => event.kind === 'reset',
    },
    url: () => `/v1/session/${session}/lines`,
    cursorOf: (event) => event.kind === 'line' ? event.line.position : null,
    retention: {
      kind: 'transcript',
      key: `${session}:lines`,
      retain: retainLines,
      maxBytes: transcriptBytes,
      pinned: 1,
    },
  }
}

function retainLines(
  kept: SessionLineEvent[],
  event: SessionLineEvent,
): SessionLineEvent[] {
  if (event.kind === 'reset') return [event]
  kept.push(event)
  return kept
}

interface ConversationPage {
  messages: ConversationMessagePayload[]
  before: number | null
  hasEarlier: boolean
  headPosition: number | null
}
