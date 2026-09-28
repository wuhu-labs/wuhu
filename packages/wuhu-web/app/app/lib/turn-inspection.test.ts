import { assertEquals } from 'jsr:@std/assert@1'
import type { SessionStreamEvent } from './contract.gen.ts'
import { foldDirect, initialDirectState } from './transcript-fold.ts'
import {
  closedInspection,
  eventDetails,
  followInspection,
  historyReturned,
  inspected,
  turnToggled,
} from './turn-inspection.ts'

function fold(events: SessionStreamEvent[]) {
  return events.reduce(foldDirect, initialDirectState)
}

Deno.test('an event opens in the inspector and a turn toggles open and closed', () => {
  const event = {
    kind: 'kernel' as const,
    generation: 0,
    position: 3,
    part: 0,
  }
  assertEquals(inspected(closedInspection, { kind: 'event', id: event }), {
    destination: { kind: 'event', id: event },
    history: [],
  })
  const open = turnToggled(new Set(), '0:3:0')
  assertEquals(open, new Set(['0:3:0']))
  assertEquals(turnToggled(open, '0:3:0'), new Set())
})

Deno.test('history can inspect a call and return without closing the sheet', () => {
  const calls = ['call-1', 'call-2']
  const history = inspected(closedInspection, { kind: 'history', calls })
  assertEquals(history, {
    destination: { kind: 'history', calls },
    history: calls,
  })
  const tool = inspected(history, { kind: 'tool', callID: 'call-2' })
  assertEquals(tool, {
    destination: { kind: 'tool', callID: 'call-2' },
    history: calls,
  })
  assertEquals(historyReturned(tool), history)
  assertEquals(historyReturned(closedInspection), closedInspection)
})

Deno.test('a tool opened from the timeline starts without a history', () => {
  const event = inspected(closedInspection, {
    kind: 'event',
    id: { kind: 'stream', attempt: 'att' },
  })
  assertEquals(inspected(event, { kind: 'tool', callID: 'call-1' }), {
    destination: { kind: 'tool', callID: 'call-1' },
    history: [],
  })
})

Deno.test('an inspector open on a streaming attempt follows it to its committed entry', () => {
  const streaming = fold([
    { kind: 'reset', generation: 2 },
    { kind: 'started', attemptId: 'att' },
    { kind: 'delta', attemptId: 'att', text: 'hel' },
  ])
  const open = inspected(closedInspection, {
    kind: 'event',
    id: { kind: 'stream', attempt: 'att' },
  })
  assertEquals(followInspection(open, streaming), open)

  const committed = [
    { kind: 'materialized', attemptId: 'att', entryId: 'abc' },
    {
      kind: 'item',
      generation: 2,
      position: 7,
      item: {
        assistant: {
          _0: {
            id: 'ABC',
            timestamp: 0,
            stopReason: 'stop',
            usage: { input_tokens: 0, output_tokens: 0, total_tokens: 3 },
            content: [
              { reasoning: { summary: 'think', redacted: false } },
              { text: { text: 'hello' } },
            ],
          },
        },
      },
    },
  ] satisfies SessionStreamEvent[]
  assertEquals(
    followInspection(open, committed.reduce(foldDirect, streaming)),
    {
      destination: {
        kind: 'event',
        id: { kind: 'kernel', generation: 2, position: 7, part: 1 },
      },
      history: [],
    },
  )
})

Deno.test('an event keeps its ordinal, stop reason and usage for the inspector', () => {
  const state = fold([
    { kind: 'reset', generation: 1 },
    {
      kind: 'item',
      generation: 1,
      position: 4,
      item: {
        assistant: {
          _0: {
            id: 'E1',
            timestamp: 0,
            stopReason: 'tool_use',
            usage: { input_tokens: 0, output_tokens: 0, total_tokens: 42 },
            content: [
              { text: { text: 'reading' } },
              {
                tool_call: {
                  id: 'c1',
                  name: 'read',
                  arguments: { path: '/a' },
                },
              },
            ],
          },
        },
      },
    },
  ])
  const details = eventDetails(state, {
    kind: 'kernel',
    generation: 1,
    position: 4,
    part: 1,
  })
  assertEquals(details?.title, 'read')
  assertEquals(details?.facts, [
    { label: 'Generation', value: '1' },
    { label: 'Position', value: '#4 · part 1' },
    { label: 'Entry', value: 'e1' },
    { label: 'Stop reason', value: 'tool_use' },
    { label: 'Tokens', value: '42' },
    { label: 'Call', value: 'c1' },
  ])
  assertEquals(details?.payload, { path: '/a' })
  assertEquals(
    eventDetails(state, {
      kind: 'kernel',
      generation: 0,
      position: 4,
      part: 0,
    }),
    null,
  )
})
