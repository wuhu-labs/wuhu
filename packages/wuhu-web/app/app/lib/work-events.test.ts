import { assertEquals } from 'jsr:@std/assert@1'
import type { SessionStreamEvent } from './contract.gen.ts'
import { foldDirect, initialDirectState } from './transcript-fold.ts'
import { workEvents } from './work-events.ts'

function kernel(events: SessionStreamEvent[]) {
  return workEvents(events.reduce(foldDirect, initialDirectState))
}

function item(position: number, raw: unknown, generation = 0) {
  return { kind: 'item' as const, generation, position, item: raw }
}

function kernelTurn(id: string, blocks: unknown[]) {
  return {
    assistant: {
      _0: {
        id,
        timestamp: 5,
        stopReason: 'stop',
        usage: { input_tokens: 0, output_tokens: 0, total_tokens: 1 },
        content: blocks,
      },
    },
  }
}

function toolResult(id: string, timestamp: number, payload: unknown) {
  return {
    toolResult: {
      _0: {
        id,
        timestamp,
        provenance: { toolCall: { _0: 'c1' } },
        payload,
      },
    },
  }
}

const readCall = {
  tool_call: { id: 'c1', name: 'read', arguments: { path: '/plan.md' } },
}

Deno.test('a kernel assistant entry becomes one event per block', () => {
  const events = kernel([
    { kind: 'reset', generation: 3 },
    item(1, kernelTurn('A', [{ text: { text: 'looking' } }, readCall]), 3),
  ])
  assertEquals(events.map((event) => event.id), [
    { kind: 'kernel', generation: 3, position: 1, part: 0 },
    { kind: 'kernel', generation: 3, position: 1, part: 1 },
  ])
  const [first, second] = events
  assertEquals(
    first?.kind === 'assistantText' ? [first.text, first.streaming] : null,
    ['looking', false],
  )
  assertEquals(second?.kind === 'toolCall' ? second.call : null, {
    callID: 'c1',
    name: 'read',
    arguments: { path: '/plan.md' },
  })
})

Deno.test('the last event of an assistant entry carries its stop reason', () => {
  const events = kernel([
    item(0, kernelTurn('A', [{ text: { text: 'looking' } }, readCall])),
  ])
  assertEquals(events.map((event) => event.stopReason), [null, 'stop'])
})

Deno.test('an assistant entry with no blocks still reports its stop', () => {
  const events = kernel([item(0, kernelTurn('A', []))])
  assertEquals(
    events.map((event) =>
      event.kind === 'assistantText' ? [event.text, event.streaming] : null
    ),
    [['', false]],
  )
  assertEquals(events.map((event) => event.stopReason), ['stop'])
})

Deno.test('tool arguments sent as provider text are parsed', () => {
  const events = kernel([
    item(
      0,
      kernelTurn('A', [{
        tool_call: { id: 'c1', name: 'read', arguments: '{"path":"/plan.md"}' },
      }]),
    ),
  ])
  const call = events[0]
  assertEquals(call?.kind === 'toolCall' ? call.call.arguments : null, {
    path: '/plan.md',
  })
})

Deno.test('a kernel tool result names the call it answers', () => {
  const events = kernel([
    item(0, kernelTurn('A', [readCall])),
    item(1, toolResult('R', 6, { read: { _0: { content: 'plan' } } })),
  ])
  const result = events[1]
  assertEquals(result?.kind === 'toolResult' ? result.result : null, {
    callID: 'c1',
    kind: 'read',
    failed: false,
    output: { content: 'plan' },
  })
  assertEquals(result?.timestamp, new Date(Date.UTC(2001, 0, 1, 0, 0, 6)))
})

Deno.test('a kernel failure payload marks its result failed', () => {
  const events = kernel([
    item(0, kernelTurn('A', [readCall])),
    item(
      1,
      toolResult('R', 6, { failure: { _0: { message: 'no such path' } } }),
    ),
    item(2, toolResult('R2', 7, { read: { _0: { content: 'plan' } } })),
  ])
  assertEquals(
    events.slice(1).map((event) =>
      event.kind === 'toolResult' ? event.result.failed : null
    ),
    [true, false],
  )
})

Deno.test('a streaming attempt is an in-progress assistant event', () => {
  const events = kernel([
    item(0, kernelTurn('A', [{ text: { text: 'done' } }])),
    { kind: 'started', attemptId: 'att' },
    { kind: 'delta', attemptId: 'att', text: 'still ' },
    { kind: 'delta', attemptId: 'att', text: 'going' },
  ])
  const last = events.at(-1)
  assertEquals(last?.id, { kind: 'stream', attempt: 'att' })
  assertEquals(
    last?.kind === 'assistantText' ? [last.text, last.streaming] : null,
    ['still going', true],
  )
})

Deno.test('a kernel input keeps its sender and attachments', () => {
  const events = kernel([item(0, {
    direct: {
      _0: {
        id: 'D',
        timestamp: 1,
        sender: { id: 'ac_owner', timeZone: 'UTC' },
        content: {
          text: 'go',
          attachments: [
            { kind: 'image', path: '/a.png', mimeType: 'image/png' },
            {
              kind: 'file',
              path: '/clip.mp4',
              mimeType: 'video/mp4',
              size: 41_943_040,
            },
          ],
        },
      },
    },
  })])
  const input = events[0]
  assertEquals(
    input?.kind === 'input'
      ? [input.input.sender, input.input.text, input.input.attachments]
      : null,
    ['ac_owner', 'go', [
      { kind: 'image', path: '/a.png', mimeType: 'image/png' },
      {
        kind: 'file',
        path: '/clip.mp4',
        mimeType: 'video/mp4',
        size: 41_943_040,
      },
    ]],
  )
})

Deno.test('replaying a source produces the same events', () => {
  const stream: SessionStreamEvent[] = [
    { kind: 'reset', generation: 1 },
    item(0, kernelTurn('A', [readCall]), 1),
    item(1, toolResult('R', 6, { read: { _0: { content: 'plan' } } }), 1),
  ]
  assertEquals(kernel(stream), kernel([...stream, ...stream]))
})

Deno.test('a kernel report carries its kind and sender', () => {
  const events = kernel([item(0, {
    message: {
      _0: {
        id: 'X',
        timestamp: 1,
        conversationID: 'dm_1',
        messageID: 'ms_1',
        sender: { id: 'ac_owner', timeZone: 'UTC' },
        senderSession: 'se_child',
        kind: 'progress',
        requestID: 'rq_1',
        owesReply: false,
        content: { text: 'halfway' },
      },
    },
  })])
  const input = events[0]
  assertEquals(
    input?.kind === 'input'
      ? [input.input.kind, input.input.senderSession]
      : null,
    ['progress', 'se_child'],
  )
})

Deno.test('a bookmark is an event', () => {
  const events = kernel([item(0, {
    bookmark: { _0: { id: 'B', timestamp: 0, name: 'before refactor' } },
  })])
  assertEquals(
    events.map((event) => event.kind === 'bookmark' ? event.name : null),
    ['before refactor'],
  )
})

Deno.test('unavailable reasoning remains inspectable and skipped media cannot renumber raw parts', () => {
  const events = kernel([item(
    0,
    kernelTurn('A', [
      { reasoning: { summary: '', redacted: true } },
      { media: { url: '/a.png', mimeType: 'image/png' } },
      { reasoning: { unencrypted: 'think', redacted: false } },
      { hosted_tool: { type: 'web_search', action: 'search' } },
    ]),
  )])
  assertEquals(
    events.map((event) =>
      event.kind === 'reasoning'
        ? event.summary
        : event.kind === 'assistantText'
        ? event.text
        : null
    ),
    ['', 'think', 'web_search · search'],
  )
  assertEquals(
    events.map((event) => event.id.kind === 'kernel' ? event.id.part : null),
    [0, 2, 3],
  )
})
