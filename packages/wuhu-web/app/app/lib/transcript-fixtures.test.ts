import {
  projectTurns,
  toolState,
  type TurnProjection,
  type WorkItem,
} from './turns.ts'
import { eventKey, type WorkEvent, type WorkEventBody } from './work-events.ts'

interface FixtureEvent {
  kind: string
  generation?: number
  position?: number
  part?: number
  attempt?: string
  text?: string
  callID?: string
  name?: string
  arguments?: unknown
  output?: unknown
  failed?: boolean
  noticeKind?: string
  origin?: { callID: string; name: string; arguments: unknown }
}
export const semanticFixtures: {
  name: string
  events: FixtureEvent[]
  working: boolean
  expectedWorking: boolean
  activeToolCallID?: string
  expected: ReturnType<typeof semanticRows>
}[] = JSON.parse(
  await Deno.readTextFile(
    new URL('./transcript-semantics.gen.json', import.meta.url),
  ),
).fixtures

export function fixtureEvent(event: FixtureEvent): WorkEvent {
  let body: WorkEventBody
  switch (event.kind) {
    case 'input':
      body = {
        kind: 'input',
        input: {
          sender: 'you',
          text: event.text ?? '',
          conversation: null,
          messageID: null,
          replyTarget: null,
          attachments: [],
          kind: 'message',
          senderSession: null,
        },
      }
      break
    case 'text':
    case 'stream':
      body = {
        kind: 'assistantText',
        text: event.text ?? '',
        streaming: event.kind === 'stream',
      }
      break
    case 'reasoning':
      body = { kind: 'reasoning', summary: event.text ?? '' }
      break
    case 'tool':
    case 'send':
      body = {
        kind: 'toolCall',
        call: {
          callID: event.callID!,
          name: event.name!,
          arguments: event.arguments ?? {},
        },
      }
      break
    case 'result':
      body = {
        kind: 'toolResult',
        result: {
          callID: event.callID ?? null,
          kind: event.failed ? 'failure' : 'success',
          failed: event.failed ?? false,
          output: event.output,
        },
      }
      break
    case 'notice':
      body = {
        kind: 'notification',
        notice: {
          kind: event.noticeKind ?? '',
          text: event.text ?? '',
          conversations: [],
        },
      }
      break
    case 'bookmark':
      body = { kind: 'bookmark', name: event.text ?? null }
      break
    case 'head':
      body = {
        kind: 'generationHead',
        head: { summary: event.text ?? '', note: null },
      }
      break
    default:
      throw new Error(`Unknown fixture event ${event.kind}`)
  }
  return {
    id: event.kind === 'stream'
      ? { kind: 'stream', attempt: event.attempt! }
      : {
        kind: 'kernel',
        generation: event.generation!,
        position: event.position!,
        part: event.part!,
      },
    timestamp: null,
    stopReason: null,
    ...body,
  }
}

export function fixtureProjection(
  fixture: {
    events: FixtureEvent[]
    working: boolean
    activeToolCallID?: string
  },
): TurnProjection {
  const origins = fixture.events.flatMap((event) =>
    event.origin
      ? [
        fixtureEvent({
          kind: 'tool',
          generation: event.generation,
          position: 0,
          part: 0,
          ...event.origin,
        }),
      ]
      : []
  )
  return projectTurns(fixture.events.map(fixtureEvent), fixture.working, {
    origins,
    runningCall: fixture.activeToolCallID ?? null,
  })
}

function calls(items: WorkItem[]) {
  return items.flatMap((item) =>
    item.content.kind === 'tool' || item.content.kind === 'send'
      ? [{ id: item.content.tool.callID, state: toolState(item.content.tool) }]
      : []
  )
}

export function semanticRows(projection: TurnProjection) {
  return projection.rows.map((row) => {
    switch (row.kind) {
      case 'input':
        return {
          id: row.key,
          kind: 'input',
          items: [eventKey(row.wake.id)],
          calls: [],
        }
      case 'divider':
        return {
          id: row.key,
          kind: 'head',
          items: [eventKey(row.event)],
          calls: [],
        }
      case 'gap':
        return { id: row.key, kind: 'gap', items: [], calls: [] }
      case 'summary':
        return {
          id: row.key,
          kind: 'summary',
          items: row.items.map((item) => item.key),
          calls: calls(row.items),
        }
      case 'item': {
        const item = row.item, content = item.content
        const kind = content.kind === 'text'
          ? item.label === 'Preamble' ? 'preamble' : 'output'
          : content.kind === 'orphanResult' ||
              (content.kind === 'tool' && item.inference === null)
          ? 'result'
          : content.kind
        return {
          id: row.key,
          kind,
          items: [item.key],
          calls: calls([item]),
          ...(item.inference === null ? {} : { inference: item.inference }),
          ...(content.kind === 'notice'
            ? {
              label: item.label,
              subject: item.subject,
              sources: item.sources,
            }
            : {}),
        }
      }
    }
  })
}

export function fixtureState(
  fixture: { events: FixtureEvent[] },
): import('./transcript-fold.ts').DirectState {
  const items = new Map<number, import('~/sdk/session').TranscriptItem>()
  const bubbles = new Map<string, string>()
  let generation = 0
  for (const event of fixture.events) {
    if (event.kind === 'stream') {
      bubbles.set(event.attempt!, event.text ?? '')
      continue
    }
    generation = event.generation!
    const position = event.position!
    const content = { text: event.text ?? '' }
    const common = { id: `entry-${position}`, timestamp: 0 }
    switch (event.kind) {
      case 'input':
        items.set(position, {
          kind: 'direct',
          value: { ...common, sender: { id: 'you', timeZone: 'UTC' }, content },
        })
        break
      case 'notice':
        items.set(position, {
          kind: 'notification',
          value: {
            ...common,
            kind: (event.noticeKind ??
              '') as import('~/sdk/session').NotificationKind,
            subscriptionID: 'fixture',
            endsSubscription: false,
            conversations: [],
            content,
          },
        })
        break
      case 'result':
        items.set(position, {
          kind: 'toolResult',
          value: {
            ...common,
            provenance: { toolCall: { _0: event.callID! } },
            payload: {
              [event.failed ? 'failure' : 'success']: { _0: event.output },
            },
          },
        })
        break
      case 'bookmark':
        items.set(position, {
          kind: 'bookmark',
          value: { ...common, name: event.text },
        })
        break
      case 'head':
        items.set(position, {
          kind: 'generationHead',
          value: { ...common, summary: event.text ?? '' },
        })
        break
      default: {
        const old = items.get(position)
        const blocks = old?.kind === 'assistant' ? old.value.content : []
        blocks[event.part!] = event.kind === 'text'
          ? { text: content }
          : event.kind === 'reasoning'
          ? { reasoning: { summary: event.text ?? '', redacted: false } }
          : {
            tool_call: {
              id: event.callID!,
              name: event.name!,
              arguments: event.arguments,
            },
          }
        items.set(position, {
          kind: 'assistant',
          value: {
            ...common,
            content: blocks,
            stopReason: fixture.events.some((e) =>
                e.position === position &&
                (e.kind === 'tool' || e.kind === 'send')
              )
              ? 'tool_use'
              : 'end_turn',
            usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 },
          },
        })
      }
    }
  }
  return {
    generation,
    items,
    bubbles,
    pendingSwaps: new Map(),
    materialized: new Map(),
    activeAttempt: null,
    executingInference: null,
  }
}
