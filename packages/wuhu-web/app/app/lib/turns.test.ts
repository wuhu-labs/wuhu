import { assert, assertEquals } from 'jsr:@std/assert@1'
import {
  fixtureEvent,
  fixtureProjection,
  semanticFixtures,
  semanticRows,
} from './transcript-fixtures.test.ts'
import {
  inferenceID,
  outgoing,
  projectTurns,
  rowAnchors,
  rowAtAnchor,
  type SendTarget,
  workDuration,
} from './turns.ts'
import { eventKey } from './work-events.ts'

for (const fixture of semanticFixtures) {
  Deno.test(`shared transcript semantics: ${fixture.name}`, () => {
    const projection = fixtureProjection(fixture)
    assertEquals(semanticRows(projection), fixture.expected)
    assertEquals(projection.isWorking, fixture.expectedWorking)
  })
  Deno.test(`shared transcript prefix invariants: ${fixture.name}`, () => {
    for (let length = 0; length <= fixture.events.length; length++) {
      const prefix = { ...fixture, events: fixture.events.slice(0, length) }
      const projection = fixtureProjection(prefix)
      const rows = semanticRows(projection)
      assertEquals(new Set(rows.map((row) => row.id)).size, rows.length)
      const calls = rows.flatMap((row) => row.calls.map((call) => call.id))
      assertEquals(new Set(calls).size, calls.length)
      const latest = prefix.events.map(fixtureEvent).map(inferenceID).filter((
        id,
      ) => id !== null).at(-1)
      for (const row of projection.rows) {
        if (row.kind === 'summary') {
          assert(row.items.length > 0)
          assert(row.items.every((item) => item.inference !== latest))
        }
      }
      for (const event of prefix.events.map(fixtureEvent)) {
        if (
          inferenceID(event) === latest &&
          (event.kind === 'reasoning' || event.kind === 'toolCall' ||
            (event.kind === 'assistantText' && event.text !== ''))
        ) {
          assert(
            projection.rows.some((row) =>
              row.kind === 'item' && row.item.key === eventKey(event.id)
            ),
            `${fixture.name}/${length}: latest item lost`,
          )
        }
      }
      assertEquals(semanticRows(fixtureProjection(prefix)), rows)
    }
  })
}

Deno.test('send and report destinations preserve existing naming and content', () => {
  const targetCases: [unknown, SendTarget][] = [
    [{ message: 'text' }, { kind: 'box' }],
    [{ message: 'text', session: 's' }, { kind: 'session', id: 's' }],
    [{ message: 'text', user: 'u' }, { kind: 'user', id: 'u' }],
    [{ message: 'text', conversation: 'c' }, { kind: 'conversation', id: 'c' }],
  ]
  for (const name of ['send_message']) {
    for (const [args, target] of targetCases) {
      assertEquals(
        outgoing({
          callID: 'c',
          name,
          arguments: args,
          result: null,
          calledAt: null,
          settledAt: null,
        }),
        { target, text: 'text' },
      )
    }
  }
  assertEquals(
    outgoing({
      callID: 'c',
      name: 'report',
      arguments: { kind: 'progress', content: 'text' },
      result: null,
      calledAt: null,
      settledAt: null,
    }),
    { target: { kind: 'report', report: 'progress' }, text: 'text' },
  )
})

Deno.test('duration comes only from available represented source and result timestamps', () => {
  const fixture = semanticFixtures.find((f) =>
    f.name === 'next-committed-folds'
  )!
  const projection = fixtureProjection(fixture)
  assertEquals(workDuration(projection.items), null)
  const events = fixture.events.map(fixtureEvent).map((event, index) => ({
    ...event,
    timestamp: new Date(index * 1000),
  }))
  const timed = projectTurns(events, false)
  const summary = timed.rows.find((row) => row.kind === 'summary')!
  assertEquals(summary.kind === 'summary' ? summary.duration : null, 6)
})

Deno.test('external inputs remain separate chronological visible boundaries', () => {
  const events = [0, 1].map((position) =>
    fixtureEvent({
      generation: 1,
      position,
      part: 0,
      kind: 'input',
      text: String(position),
    })
  )
  assertEquals(projectTurns(events, false).rows.map((row) => row.key), [
    '1:0:0',
    '1:1:0',
  ])
})

Deno.test('a receipt source anchor survives its companion joining a folded declaration', () => {
  const tail = fixtureProjection(
    semanticFixtures.find((f) =>
      f.name === 'receipt-first-tail-with-companion'
    )!,
  )
  const joined = fixtureProjection(
    semanticFixtures.find((f) =>
      f.name === 'receipt-tail-prepend-folded-declaration'
    )!,
  )
  assertEquals(rowAtAnchor(tail, '7:8:0')?.key, '7:8:0')
  const summary = rowAtAnchor(joined, '7:8:0')!
  assertEquals(summary.key, 'summary:7:7:0')
  assertEquals(rowAnchors(summary), ['7:7:0', '7:7:1', '7:8:0'])
  assertEquals(joined.items.length, 3)
  assertEquals(summary.kind === 'summary' ? summary.tools : null, 1)
})
