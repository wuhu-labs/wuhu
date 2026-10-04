import type { DirectState } from './transcript-fold.ts'
import {
  type Attachment,
  type ContentBlock,
  swiftDate,
  type TranscriptItem,
} from '~/sdk/session'

export type WorkEventID =
  | { kind: 'kernel'; generation: number; position: number; part: number }
  | { kind: 'stream'; attempt: string }

export function eventKey(id: WorkEventID): string {
  return id.kind === 'kernel'
    ? `${id.generation}:${id.position}:${id.part}`
    : `stream:${id.attempt}`
}

export interface WorkInput {
  sender: string
  text: string
  conversation: string | null
  messageID: string | null
  replyTarget: string | null
  attachments: Attachment[]
  kind: string
  senderSession: string | null
}

export interface WorkNotice {
  kind: string
  text: string
  conversations: string[]
}

export interface WorkToolCall {
  callID: string
  name: string
  arguments: unknown
}

export interface WorkToolResult {
  callID: string | null
  kind: string
  failed: boolean
  output: unknown
}

export interface WorkHead {
  summary: string
  note: string | null
}

export type WorkEventBody =
  | { kind: 'input'; input: WorkInput }
  | { kind: 'notification'; notice: WorkNotice }
  | { kind: 'assistantText'; text: string; streaming: boolean }
  | { kind: 'reasoning'; summary: string }
  | { kind: 'toolCall'; call: WorkToolCall }
  | { kind: 'toolResult'; result: WorkToolResult }
  | { kind: 'bookmark'; name: string | null }
  | { kind: 'generationHead'; head: WorkHead }

export type WorkEvent = {
  id: WorkEventID
  timestamp: Date | null
  // Why the assistant entry this event closes stopped; null on every other event.
  stopReason: string | null
} & WorkEventBody

export function workEvents(state: DirectState): WorkEvent[] {
  const entries = [...state.items.entries()].sort(([a], [b]) => a - b)
  const events = entries.flatMap(([position, item]) =>
    itemEvents(item, state.generation, position)
  )
  for (const [attempt, text] of state.bubbles) {
    events.push({
      id: { kind: 'stream', attempt },
      timestamp: null,
      stopReason: null,
      kind: 'assistantText',
      text,
      streaming: true,
    })
  }
  return events
}

type Block =
  & (
    | { kind: 'text'; text: string }
    | { kind: 'reasoning'; summary: string }
    | { kind: 'toolCall'; call: WorkToolCall }
    | { kind: 'hostedTool'; digest: string }
  )
  & { part: number }

// Arguments travel as the text the provider emitted; spaces older than that
// send a JSON object.
function toolArguments(value: unknown): unknown {
  if (typeof value !== 'string') return value
  try {
    return JSON.parse(value)
  } catch {
    return value
  }
}

export function assistantBlocks(content: ContentBlock[]): Block[] {
  return content.flatMap((block, part): Block[] => {
    if ('text' in block) return [{ part, kind: 'text', text: block.text.text }]
    if ('reasoning' in block) {
      const summary = block.reasoning.unencrypted ?? block.reasoning.summary ??
        ''
      return [{ part, kind: 'reasoning', summary }]
    }
    if ('tool_call' in block) {
      return [{
        part,
        kind: 'toolCall',
        call: {
          callID: block.tool_call.id,
          name: block.tool_call.name,
          arguments: toolArguments(block.tool_call.arguments),
        },
      }]
    }
    if ('hosted_tool' in block) {
      return [{
        part,
        kind: 'hostedTool',
        digest: `${block.hosted_tool.type} · ${block.hosted_tool.action}`,
      }]
    }
    return []
  })
}

function blockBody(block: Block): WorkEventBody {
  switch (block.kind) {
    case 'text':
      return { kind: 'assistantText', text: block.text, streaming: false }
    case 'reasoning':
      return { kind: 'reasoning', summary: block.summary }
    case 'toolCall':
      return { kind: 'toolCall', call: block.call }
    case 'hostedTool':
      return { kind: 'assistantText', text: block.digest, streaming: false }
  }
}

export function toolResultOf(
  value: Extract<TranscriptItem, { kind: 'toolResult' }>['value'],
): WorkToolResult {
  const [kind, payload] = Object.entries(value.payload)[0]!
  const output =
    typeof payload === 'object' && payload !== null && '_0' in payload
      ? (payload as { _0: unknown })._0
      : payload
  return {
    callID: 'toolCall' in value.provenance
      ? value.provenance.toolCall._0
      : null,
    kind,
    failed: kind === 'failure',
    output,
  }
}

function itemEvents(
  item: TranscriptItem,
  generation: number,
  position: number,
): WorkEvent[] {
  const event = (
    part: number,
    timestamp: Date | null,
    body: WorkEventBody,
    stopReason: string | null = null,
  ): WorkEvent => ({
    id: { kind: 'kernel', generation, position, part },
    timestamp,
    stopReason,
    ...body,
  })
  switch (item.kind) {
    case 'direct': {
      const message = item.value
      return [event(0, swiftDate(message.timestamp), {
        kind: 'input',
        input: {
          sender: message.sender.id,
          text: message.content.text,
          conversation: null,
          messageID: null,
          replyTarget: null,
          attachments: message.content.attachments ?? [],
          kind: 'message',
          senderSession: null,
        },
      })]
    }
    case 'message': {
      const message = item.value
      return [event(0, swiftDate(message.timestamp), {
        kind: 'input',
        input: {
          sender: message.sender.id,
          text: message.content.text,
          conversation: message.conversationID,
          messageID: message.messageID,
          replyTarget: message.replyTarget ?? null,
          attachments: message.content.attachments ?? [],
          kind: message.kind,
          senderSession: message.senderSession ?? null,
        },
      })]
    }
    case 'notification': {
      const notice = item.value
      return [event(0, swiftDate(notice.timestamp), {
        kind: 'notification',
        notice: {
          kind: notice.kind,
          text: notice.content.text,
          conversations: notice.conversations,
        },
      })]
    }
    case 'assistant': {
      const entry = item.value
      const at = swiftDate(entry.timestamp)
      const blocks = assistantBlocks(entry.content)
      // The last event carries the stop reason; an entry with no blocks still
      // yields an empty text so the stop is seen.
      if (blocks.length === 0) {
        return [
          event(
            0,
            at,
            { kind: 'assistantText', text: '', streaming: false },
            entry.stopReason,
          ),
        ]
      }
      return blocks.map((block, index) =>
        event(
          block.part,
          at,
          blockBody(block),
          index === blocks.length - 1 ? entry.stopReason : null,
        )
      )
    }
    case 'toolResult':
      return [event(0, swiftDate(item.value.timestamp), {
        kind: 'toolResult',
        result: toolResultOf(item.value),
      })]
    case 'bookmark':
      return [
        event(0, null, { kind: 'bookmark', name: item.value.name ?? null }),
      ]
    case 'generationHead':
      return [event(0, null, {
        kind: 'generationHead',
        head: { summary: item.value.summary, note: item.value.note ?? null },
      })]
  }
}

export function runningCall(
  state: DirectState,
  working: boolean,
  live: boolean,
): string | null {
  if (
    !working || !live || state.executingInference == null ||
    state.activeAttempt != null
  ) return null
  const position = state.executingInference
  const item = state.items.get(position)
  if (
    item?.kind !== 'assistant' ||
    !['tool_use', 'toolUse'].includes(item.value.stopReason)
  ) return null
  for (const [at, entry] of state.items) {
    if (at > position && entry.kind === 'assistant') return null
  }
  const received = new Set(
    [...state.items.values()].flatMap((entry) =>
      entry.kind === 'toolResult' ? [toolResultOf(entry.value).callID] : []
    ),
  )
  const next = assistantBlocks(item.value.content).find((block) =>
    block.kind === 'toolCall' && !received.has(block.call.callID)
  )
  return next?.kind === 'toolCall' ? next.call.callID : null
}
