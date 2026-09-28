import type { DirectState } from './transcript-fold.ts'
import { noticeLabel } from './turn-labels.ts'
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
  | { kind: 'history'; calls: string[] }
  | { kind: 'event'; id: WorkEventID }

export interface Inspection {
  destination: Destination | null
  history: string[]
}

export const closedInspection: Inspection = { destination: null, history: [] }

// A tool opened from a tool history keeps that history to return to; anything
// else opened starts afresh.
export function inspected(
  inspection: Inspection,
  destination: Destination,
): Inspection {
  if (
    destination.kind === 'tool' && inspection.destination?.kind === 'history'
  ) return { ...inspection, destination }
  return {
    destination,
    history: destination.kind === 'history' ? destination.calls : [],
  }
}

export function historyReturned(inspection: Inspection): Inspection {
  return inspection.history.length === 0 ? inspection : {
    ...inspection,
    destination: { kind: 'history', calls: inspection.history },
  }
}

export function turnToggled(
  expanded: ReadonlySet<string>,
  turn: string,
): ReadonlySet<string> {
  const next = new Set(expanded)
  if (!next.delete(turn)) next.add(turn)
  return next
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
    ? Math.max(
      0,
      assistantBlocks(item.value.content).findIndex((block) =>
        block.kind === 'text'
      ),
    )
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
        title: noticeLabel(item.value.kind),
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
  const block = blocks[part]
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
