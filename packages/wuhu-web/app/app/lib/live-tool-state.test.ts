import { assertEquals } from 'jsr:@std/assert@1'
import type { SessionStreamEvent } from './contract.gen.ts'
import {
  type DirectState,
  foldDirect,
  initialDirectState,
} from './transcript-fold.ts'
import { runningCall, workEvents } from './work-events.ts'
import { activity, projectTurns, toolState } from './turns.ts'

function assistant(
  position: number,
  id: string,
  calls: string[],
  stopReason = 'tool_use',
): SessionStreamEvent {
  return {
    kind: 'item',
    generation: 0,
    position,
    item: {
      assistant: {
        _0: {
          id,
          timestamp: 0,
          content: calls.map((id) => ({
            tool_call: { id, name: 'read', arguments: '{}' },
          })),
          stopReason,
          usage: { input_tokens: 0, output_tokens: 0, total_tokens: 0 },
        },
      },
    },
  }
}
function receipt(position: number, callID: string): SessionStreamEvent {
  return {
    kind: 'item',
    generation: 0,
    position,
    item: {
      toolResult: {
        _0: {
          id: `result-${callID}`,
          timestamp: 1,
          provenance: { toolCall: { _0: callID } },
          payload: { success: { _0: 'received' } },
        },
      },
    },
  }
}
function commit(
  position: number,
  id: string,
  calls: string[],
): SessionStreamEvent[] {
  return [{ kind: 'started', attemptId: id }, {
    kind: 'materialized',
    attemptId: id,
    entryId: id,
  }, assistant(position, id, calls)]
}
function folded(events: SessionStreamEvent[], state = initialDirectState) {
  return events.reduce(foldDirect, state)
}
function projection(state: DirectState, working = true, live = true) {
  return projectTurns(workEvents(state), working, {
    origins: [],
    runningCall: runningCall(state, working, live),
  })
}
function stateOf(state: DirectState, id: string, working = true, live = true) {
  return toolState(activity(projection(state, working, live), id)!)
}

Deno.test('current live materialized tool-use inference runs only its first unfinished call', () => {
  let state = folded(commit(10, 'live', ['a', 'b']))
  assertEquals(stateOf(state, 'a'), 'running')
  assertEquals(stateOf(state, 'b'), 'queued')
  assertEquals(stateOf(state, 'a', false), 'unknown')
  assertEquals(stateOf(state, 'a', true, false), 'unknown')
  state = folded([receipt(11, 'a')], state)
  assertEquals(stateOf(state, 'a'), 'done')
  assertEquals(stateOf(state, 'b'), 'running')
})

Deno.test('an aborted old inference stays Unknown when a later live inference executes', () => {
  const histories: SessionStreamEvent[][] = [
    [...commit(10, 'old', ['old-call']), {
      kind: 'cancelled',
      attemptId: 'old',
      reason: 'interrupted',
    }],
    [assistant(10, 'old', ['old-call'], 'aborted')],
  ]
  for (const history of histories) {
    const state = folded([...history, ...commit(20, 'new', ['new-call'])])
    assertEquals(stateOf(state, 'old-call'), 'unknown')
    assertEquals(stateOf(state, 'new-call'), 'running')
  }
})

Deno.test('a newer attempt or assistant invalidates old execution evidence, not session-global working', () => {
  let state = folded(commit(10, 'old', ['old-call']))
  state = folded([{ kind: 'started', attemptId: 'later' }], state)
  assertEquals(stateOf(state, 'old-call'), 'unknown')
  state = folded(
    [{ kind: 'cancelled', attemptId: 'later', reason: 'aborted' }],
    state,
  )
  assertEquals(stateOf(state, 'old-call'), 'unknown')
  state = folded([assistant(20, 'later', ['aborted-call'], 'aborted')], state)
  assertEquals(stateOf(state, 'aborted-call'), 'unknown')
})

Deno.test('snapshot and origin-only declarations are Unknown or invisible without current live evidence', () => {
  const state = folded([assistant(10, 'snapshot', ['unknown'])])
  assertEquals(stateOf(state, 'unknown'), 'unknown')
  const originOnly = projectTurns([], true, {
    origins: workEvents(state),
    runningCall: runningCall(state, true, true),
  })
  assertEquals(activity(originOnly, 'unknown'), null)
})

Deno.test('origin companion with a loaded receipt is Done without becoming execution evidence', () => {
  const origins = folded([assistant(10, 'origin', ['a', 'unloaded'])])
  const state = folded([receipt(20, 'a')])
  const projected = projectTurns(workEvents(state), true, {
    origins: workEvents(origins),
    runningCall: runningCall(state, true, true),
  })
  assertEquals(toolState(activity(projected, 'a')!), 'done')
  assertEquals(activity(projected, 'unloaded'), null)
})

Deno.test('delayed old commit cannot replace the current attempt as execution evidence', () => {
  const state = folded([
    { kind: 'started', attemptId: 'old' },
    { kind: 'started', attemptId: 'new' },
    { kind: 'materialized', attemptId: 'old', entryId: 'old' },
    assistant(10, 'old', ['old-call']),
  ])
  assertEquals(stateOf(state, 'old-call'), 'unknown')
})

Deno.test('same-generation reset clears live execution evidence without losing retained legacy rows', () => {
  const before = folded(commit(10, 'live', ['a']))
  const after = folded([{ kind: 'reset', generation: 0 }], before)
  assertEquals(after.items.size, 1)
  assertEquals(stateOf(after, 'a'), 'unknown')
})
