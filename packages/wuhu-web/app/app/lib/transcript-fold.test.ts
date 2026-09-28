import type { SessionStreamEvent } from './contract.gen.ts'
import {
  foldDirect,
  initialDirectState,
  parseTranscriptItem,
} from './transcript-fold.ts'

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message)
}

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

function fold(events: SessionStreamEvent[]) {
  return events.reduce(foldDirect, initialDirectState)
}

function assistantItem(id: string) {
  return {
    assistant: {
      _0: {
        id,
        timestamp: 0,
        content: [{ text: { text: 'hi' } }],
        stopReason: 'end',
        usage: { input_tokens: 0, output_tokens: 0, total_tokens: 0 },
      },
    },
  }
}

Deno.test('parseTranscriptItem unwraps the Codable _0 envelope', () => {
  const parsed = parseTranscriptItem(assistantItem('ABC'))
  assertEquals(parsed?.kind, 'assistant')
  assertEquals((parsed?.value as { id: string }).id, 'ABC')
})

Deno.test('reset sets the generation and clears items', () => {
  const state = fold([
    { kind: 'item', generation: 0, position: 0, item: assistantItem('A') },
    { kind: 'reset', generation: 1 },
  ])
  assertEquals(state.generation, 1)
  assertEquals(state.items.size, 0)
})

Deno.test('item from a stale generation is ignored', () => {
  const state = fold([
    { kind: 'reset', generation: 2 },
    { kind: 'item', generation: 1, position: 0, item: assistantItem('A') },
  ])
  assertEquals(state.items.size, 0)
})

Deno.test('delta accumulates and a repeated started restarts the bubble', () => {
  const state = fold([
    { kind: 'started', attemptId: 'att' },
    { kind: 'delta', attemptId: 'att', text: 'hel' },
    { kind: 'delta', attemptId: 'att', text: 'lo' },
    { kind: 'started', attemptId: 'att' },
    { kind: 'delta', attemptId: 'att', text: 'hello world' },
  ])
  assertEquals(state.bubbles.get('att'), 'hello world')
})

Deno.test('cancelled removes the bubble', () => {
  const state = fold([
    { kind: 'started', attemptId: 'att' },
    { kind: 'delta', attemptId: 'att', text: 'x' },
    { kind: 'cancelled', attemptId: 'att', reason: 'stop' },
  ])
  assertEquals(state.bubbles.has('att'), false)
})

Deno.test('materialize then committed item swaps the bubble out', () => {
  const state = fold([
    { kind: 'started', attemptId: 'att' },
    { kind: 'delta', attemptId: 'att', text: 'answer' },
    { kind: 'materialized', attemptId: 'att', entryId: 'abc' },
    { kind: 'item', generation: 0, position: 0, item: assistantItem('ABC') },
  ])
  assert(state.bubbles.size === 0, 'bubble should be swapped out')
  assertEquals(state.items.size, 1)
  assertEquals(state.pendingSwaps.size, 0)
  assertEquals([...state.materialized], [['att', 0]])
})

Deno.test('a reset to the same generation keeps items while replay upserts them', () => {
  const state = fold([
    { kind: 'reset', generation: 1 },
    { kind: 'item', generation: 1, position: 0, item: assistantItem('A') },
    { kind: 'reset', generation: 1 },
  ])
  assertEquals(state.items.size, 1)
})

Deno.test('a reset to a new generation forgets its materialized attempts', () => {
  const state = fold([
    { kind: 'started', attemptId: 'att' },
    { kind: 'materialized', attemptId: 'att', entryId: 'abc' },
    { kind: 'item', generation: 0, position: 0, item: assistantItem('ABC') },
    { kind: 'reset', generation: 1 },
  ])
  assertEquals(state.items.size, 0)
  assertEquals(state.materialized.size, 0)
})

Deno.test('foldDirect does not mutate the input state', () => {
  const before = initialDirectState
  foldDirect(before, { kind: 'started', attemptId: 'att' })
  assertEquals(before.bubbles.size, 0)
})

Deno.test('transcript message keeps request and reply metadata from the wire', () => {
  const raw = {
    message: {
      _0: {
        id: 'entry',
        messageID: 'message',
        conversationID: 'box',
        sender: { id: 'agent', timeZone: 'UTC' },
        timestamp: 0,
        kind: 'final',
        requestID: 'request-1',
        replyTarget: 'earlier',
        deadline: 42,
        owesReply: false,
        content: { text: 'done' },
      },
    },
  }
  const item = parseTranscriptItem(raw)
  if (item?.kind !== 'message') throw new Error('wrong kind')
  assertEquals([
    item.value.kind,
    item.value.requestID,
    item.value.replyTarget,
    item.value.deadline,
  ], ['final', 'request-1', 'earlier', 42])
})

Deno.test('unrecognized transcript kinds do not interrupt the direct stream', () => {
  const state = fold([
    {
      kind: 'item',
      generation: 0,
      position: 0,
      item: { futureItem: { _0: { id: 'new' } } },
    },
    { kind: 'item', generation: 0, position: 1, item: assistantItem('known') },
  ])
  assertEquals(state.items.size, 1)
  assertEquals(state.items.get(1)?.kind, 'assistant')
})
