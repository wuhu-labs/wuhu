import type { SpaceClient } from './client'
import type {
  ConversationMessagePayload,
  MutationEvent,
  QueryOutput,
  SessionStreamEvent,
} from '~/lib/contract.gen'
import type { Subscription } from './observe'
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
  return {
    group,
    from: null,
    url: () => url,
    cursorOf: () => null,
    retention: {
      kind: 'transcript',
      key: session,
      retain: retainTranscript,
      maxBytes: transcriptBytes,
      pinned: 1,
    },
  }
}

// Every connect replays the generation from its reset, so a reset starts the
// record over and stays at its head; bubbles in flight are not worth a
// reopen's paint.
function retainTranscript(
  kept: SessionStreamEvent[],
  event: SessionStreamEvent,
): SessionStreamEvent[] {
  if (event.kind === 'reset') return [event]
  if (event.kind !== 'item') return kept
  kept.push(event)
  return kept
}
