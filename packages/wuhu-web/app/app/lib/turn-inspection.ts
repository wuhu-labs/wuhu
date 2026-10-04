import type { DirectState } from './transcript-fold.ts'
import {
  noticePresentation,
  type TranscriptRow,
  type TurnProjection,
} from './turns.ts'
import {
  assistantBlocks,
  toolResultOf,
  type WorkEventID,
} from './work-events.ts'
import {
  type AssistantEntry,
  swiftDate,
  type TranscriptItem,
} from '~/sdk/session'

export type Destination =
  | { kind: 'tool'; callID: string }
  | { kind: 'history'; summary: string }
  | { kind: 'event'; id: WorkEventID }

export interface Inspection {
  destination: Destination | null
  history: string | null
}

export const closedInspection: Inspection = { destination: null, history: null }

export function inspected(
  inspection: Inspection,
  destination: Destination,
): Inspection {
  if (
    destination.kind !== 'history' && inspection.destination?.kind === 'history'
  ) return { ...inspection, destination }
  return {
    destination,
    history: destination.kind === 'history' ? destination.summary : null,
  }
}

export function historyReturned(inspection: Inspection): Inspection {
  return inspection.history === null ? inspection : {
    ...inspection,
    destination: { kind: 'history', summary: inspection.history },
  }
}

export function historyRow(
  projection: TurnProjection,
  key: string,
): Extract<TranscriptRow, { kind: 'summary' }> | null {
  const anchor = key.replace(/^summary:/, '')
  return projection.rows.find((
    row,
  ): row is Extract<TranscriptRow, { kind: 'summary' }> =>
    row.kind === 'summary' &&
    (row.key === key || row.items.some((item) => item.key === anchor))
  ) ?? null
}

export function validInspection(
  inspection: Inspection,
  projection: TurnProjection,
  state: DirectState,
): Inspection {
  const destination = inspection.destination
  if (destination === null) return inspection
  const valid = destination.kind === 'history'
    ? historyRow(projection, destination.summary) !== null
    : destination.kind === 'tool'
    ? projection.items.some((item) =>
      (item.content.kind === 'tool' || item.content.kind === 'send') &&
      item.content.tool.callID === destination.callID
    )
    : eventDetails(state, destination.id) !== null
  return valid ? inspection : closedInspection
}

// An event opened while its text was still streaming follows the attempt to
// the entry it was committed as.
export function followInspection(
  inspection: Inspection,
  state: DirectState,
): Inspection {
  const destination = inspection.destination
  if (destination?.kind !== 'event' || destination.id.kind !== 'stream') {
    return inspection
  }
  const position = state.materialized.get(destination.id.attempt)
  if (position === undefined) return inspection
  const item = state.items.get(position)
  const part = item?.kind === 'assistant'
    ? assistantBlocks(item.value.content).find((block) => block.kind === 'text')
      ?.part ?? 0
    : 0

  return {
    ...inspection,
    destination: {
      kind: 'event',
      id: { kind: 'kernel', generation: state.generation, position, part },
    },
  }
}

export interface EventDetails {
  title: string
  timestamp: Date | null
  facts: { label: string; value: string }[]
  text: string | null
  payload: unknown
}

function facts(
  pairs: [string, string | null | undefined][],
): EventDetails['facts'] {
  return pairs.flatMap(([label, value]) =>
    value == null || value === '' ? [] : [{ label, value }]
  )
}

export function eventDetails(
  state: DirectState,
  id: WorkEventID,
): EventDetails | null {
  if (id.kind === 'stream') {
    const text = state.bubbles.get(id.attempt)
    if (text === undefined) return null
    return {
      title: 'Assistant text',
      timestamp: null,
      facts: facts([['Attempt', id.attempt], ['State', 'Streaming']]),
      text,
      payload: undefined,
    }
  }
  const item = id.generation === state.generation
    ? state.items.get(id.position)
    : undefined
  if (item === undefined) return null
  const details = itemDetails(item, id.part)
  details.facts.unshift(
    { label: 'Generation', value: String(id.generation) },
    {
      label: 'Position',
      value: `#${id.position}${id.part > 0 ? ` · part ${id.part}` : ''}`,
    },
  )
  return details
}

function itemDetails(item: TranscriptItem, part: number): EventDetails {
  switch (item.kind) {
    case 'direct':
      return {
        title: 'Direct input',
        timestamp: swiftDate(item.value.timestamp),
        facts: facts([['Sender', item.value.sender.id]]),
        text: item.value.content.text,
        payload: undefined,
      }
    case 'message': {
      const message = item.value
      return {
        title: message.kind === 'final' || message.kind === 'progress'
          ? `Report · ${message.kind}`
          : message.kind === 'request'
          ? 'Request'
          : 'Message',
        timestamp: swiftDate(message.timestamp),
        facts: facts([
          ['Sender', message.sender.id],
          ['Session', message.senderSession],
          ['Conversation', message.conversationID],
          ['Message', message.messageID],
          ['Reply to', message.replyTarget],
          ['Request', message.requestID],
          ['Kind', message.kind],
        ]),
        text: message.content.text,
        payload: undefined,
      }
    }
    case 'notification':
      return {
        title: noticePresentation({
          kind: item.value.kind,
          text: item.value.content.text,
          conversations: item.value.conversations,
        }).label,
        timestamp: swiftDate(item.value.timestamp),
        facts: facts([
          ['Kind', item.value.kind],
          ['Conversations', item.value.conversations.join(', ')],
        ]),
        text: item.value.content.text,
        payload: undefined,
      }
    case 'assistant':
      return assistantDetails(item.value, part)
    case 'toolResult': {
      const result = toolResultOf(item.value)
      return {
        title: 'Tool result',
        timestamp: swiftDate(item.value.timestamp),
        facts: facts([
          ['Result', item.value.id],
          ['Call', result.callID],
          ['Kind', result.kind],
        ]),
        text: null,
        payload: result.output,
      }
    }
    case 'bookmark':
      return {
        title: 'Bookmark',
        timestamp: null,
        facts: facts([['Name', item.value.name], [
          'Call',
          item.value.toolCallID,
        ]]),
        text: null,
        payload: undefined,
      }
    case 'generationHead': {
      const { summary, note } = item.value
      return {
        title: summary === '' ? 'Started over' : 'Context continued',
        timestamp: null,
        facts: [],
        text: [summary, note == null ? '' : `Note: ${note}`]
          .filter((part) => part !== '').join('\n\n'),
        payload: undefined,
      }
    }
  }
}

function assistantDetails(entry: AssistantEntry, part: number): EventDetails {
  const details: EventDetails = {
    title: 'Assistant',
    timestamp: swiftDate(entry.timestamp),
    facts: facts([
      ['Entry', entry.id.toLowerCase()],
      ['Stop reason', entry.stopReason],
      [
        'Tokens',
        entry.usage.total_tokens > 0 ? String(entry.usage.total_tokens) : null,
      ],
    ]),
    text: null,
    payload: undefined,
  }
  const blocks = assistantBlocks(entry.content)
  const block = blocks.find((block) => block.part === part)
  switch (block?.kind) {
    case 'text':
      return { ...details, title: 'Assistant text', text: block.text }
    case 'reasoning':
      return { ...details, title: 'Reasoning', text: block.summary }
    case 'toolCall':
      return {
        ...details,
        title: block.call.name,
        facts: [...details.facts, { label: 'Call', value: block.call.callID }],
        payload: block.call.arguments,
      }
    case 'hostedTool':
      return { ...details, title: 'Hosted tool', text: block.digest }
    case undefined:
      return {
        ...details,
        text: blocks.flatMap((each) => each.kind === 'text' ? [each.text] : [])
          .join('\n\n'),
      }
  }
}
