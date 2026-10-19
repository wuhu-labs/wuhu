import {
  executorLabel,
  isSessionWorking,
  lookupSession,
  rosterModelLabel,
  sessionRunState,
  sessionStatus,
} from './session-model.ts'

function equal(actual: unknown, expected: unknown) {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

const roster = [{ id: 'scout' }]

Deno.test('a session in the roster is found', () => {
  equal(lookupSession(roster, 'scout', false), {
    kind: 'found',
    record: { id: 'scout' },
  })
})

Deno.test('every id is loading until the roster arrives', () => {
  equal(lookupSession(null, 'scout', false), { kind: 'loading' })
  equal(lookupSession(null, 'fresh', true), { kind: 'loading' })
})

Deno.test('an id this tab just created stays loading until the roster lists it', () => {
  equal(lookupSession(roster, 'fresh', true), { kind: 'loading' })
})

Deno.test('any other id missing from the loaded roster is not found', () => {
  equal(lookupSession(roster, 'nobody', false), { kind: 'missing' })
})

Deno.test('a route waiting on its member is named, after errors', () => {
  const route = {
    group: 'fleet',
    member: 'primary',
    phase: 'waiting',
    epoch: '1',
    reason: 'create',
    previousMember: null,
    failureRevision: null,
  }
  const waiting = sessionStatus({
    hold: 'live',
    work: 'has_work',
    runState: 'inference',
    route,
  })
  if (waiting?.label !== 'waiting on model') {
    throw new Error(String(waiting?.label))
  }
  const errored = sessionStatus({
    hold: 'errored',
    work: 'errored',
    runState: 'no_run',
    route,
  })
  if (errored?.label !== 'errored') throw new Error(String(errored?.label))
})

Deno.test('a group session names its group and the member it runs on', () => {
  equal(
    executorLabel('kernel', '{"modelGroup":"fleet","effort":"high"}'),
    'fleet',
  )
  equal(
    executorLabel('kernel', '{"provider":"codex","model":"gpt-6-sol"}'),
    'codex/gpt-6-sol',
  )
  const route = {
    group: 'fleet',
    member: 'backup',
    phase: 'pinned',
    epoch: '1',
    reason: 'create',
    previousMember: null,
    failureRevision: null,
  }
  // The server stores a group session's concrete member executor.
  const stored = executorLabel(
    'kernel',
    '{"provider":"anthropic","model":"claude-opus-5","effort":"high"}',
  )
  equal(stored, 'anthropic/claude-opus-5')
  equal(rosterModelLabel({ executorLabel: stored, route }), 'fleet → backup')
  equal(
    rosterModelLabel({ executorLabel: 'codex/gpt-6-sol' }),
    'codex/gpt-6-sol',
  )
})

Deno.test('run state decodes known and future wire values without using pending work', () => {
  for (
    const [wire, expected] of [
      ['inference', true],
      ['tool', true],
      ['no_run', false],
      ['future', false],
      [null, false],
    ] as const
  ) {
    const runState = sessionRunState(wire)
    equal(isSessionWorking({ runState }), expected)
    equal(
      sessionStatus({ hold: 'normal', work: 'has_work', runState }),
      expected ? { label: 'working', tone: 'amber' } : null,
    )
  }
  equal(sessionRunState('future'), 'unknown')
  equal(
    sessionStatus({
      hold: 'interrupted',
      work: 'has_work',
      runState: 'no_run',
    }),
    { label: 'interrupted', tone: 'neutral' },
  )
})
