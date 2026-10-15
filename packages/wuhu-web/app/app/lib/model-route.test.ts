import {
  routeFailureOf,
  routeNote,
  routeNotice,
  routeNoticeLine,
  routeRows,
  type SessionRoute,
  stillRecovered,
  withRoutes,
} from './model-route.ts'

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

const time = (when: Date) => when.toISOString().slice(11, 16)

const pinned: SessionRoute = {
  group: 'fleet',
  member: 'primary',
  phase: 'pinned',
  epoch: '3',
  reason: 'create',
  previousMember: null,
  failureRevision: null,
}
const waiting: SessionRoute = { ...pinned, phase: 'waiting' }
const now = new Date('2026-10-14T21:00:00Z')

Deno.test('route rows key by session and skip direct sessions', () => {
  const routes = routeRows({
    columns: [],
    rows: [
      [
        's1',
        'fleet',
        'primary',
        'pinned',
        '3',
        'create',
        null,
        null,
      ],
      ['s2', null, null, null, null, null, null, null],
    ],
  })
  assertEquals([...routes.keys()], ['s1'])
  assertEquals(routes.get('s1'), pinned)
})

Deno.test('a route without a failure reads none', () => {
  assertEquals(routeFailureOf({ requestedTarget: null, route: {} }), null)
})

Deno.test('a pinned route names the group and its member', () => {
  assertEquals(routeNote(pinned, null, false, now, time), {
    stage: 'pinned',
    text: 'fleet → primary',
    tone: 'neutral',
  })
})

Deno.test('waiting shows the switch deadline, and passing it blocks', () => {
  const failure = {
    reason: 'quota',
    source: 'inference',
    code: null,
    deadline: new Date('2026-10-14T21:05:00Z'),
    retryAt: new Date('2026-10-14T21:10:00Z'),
  }
  assertEquals(routeNote(waiting, failure, false, now, time), {
    stage: 'waiting',
    text: 'Waiting on primary · switch eligible 21:05',
    tone: 'amber',
  })
  const later = new Date('2026-10-14T21:06:00Z')
  assertEquals(routeNote(waiting, failure, false, later, time), {
    stage: 'blocked',
    text: 'fleet blocked on primary: quota exhaustion · next retry 21:10',
    tone: 'rose',
  })
  assertEquals(
    routeNote(
      waiting,
      { ...failure, reason: 'authentication' },
      false,
      later,
      time,
    ).text,
    'fleet blocked on primary: an authentication failure · sign-in required',
  )
  assertEquals(
    routeNote(waiting, failure, false, later, time, true).text,
    'fleet blocked on primary · next retry 21:10',
  )
})

Deno.test('a last-resort move names the member it left', () => {
  const moved = {
    ...pinned,
    member: 'spare',
    reason: 'lastResort:quota',
    previousMember: 'primary',
  }
  assertEquals(routeNote(moved, null, false, now, time), {
    stage: 'switched',
    text: 'fleet → spare · switched from primary after quota exhaustion',
    tone: 'neutral',
  })
  assertEquals(
    routeNote({ ...moved, reason: 'lastResort:novel' }, null, false, now, time)
      .text,
    'fleet → spare · switched from primary after novel',
  )
})

Deno.test('recovery is live only: waiting then pinned on the same epoch', () => {
  assertEquals(stillRecovered(waiting, pinned, false), true)
  assertEquals(stillRecovered(pinned, pinned, true), true)
  assertEquals(stillRecovered(null, pinned, false), false)
  assertEquals(stillRecovered(waiting, { ...pinned, epoch: '4' }, false), false)
  assertEquals(stillRecovered(pinned, waiting, true), false)
  assertEquals(routeNote(pinned, null, true, now, time), {
    stage: 'recovered',
    text: 'fleet → primary · recovered',
    tone: 'live',
  })
})

Deno.test('a route notice keeps an unknown reason and drops a missing portability line', () => {
  const notice = routeNotice(
    'Model group fleet moved primary → backup (novelPlacement).',
  )
  assertEquals(notice, {
    group: 'fleet',
    from: 'primary',
    to: 'backup',
    reason: 'novelPlacement',
    portable: false,
  })
  assertEquals(
    routeNoticeLine(notice!),
    'fleet: primary → backup · novelPlacement',
  )
  assertEquals(routeNotice('Context updated'), null)
})

Deno.test('known reasons pin, last resorts switch, other reasons render verbatim', () => {
  for (const reason of ['create', 'startOver', 'compaction', null]) {
    assertEquals(
      routeNote({ ...pinned, reason }, null, false, now, time).text,
      'fleet → primary',
    )
  }
  assertEquals(
    routeNote({ ...pinned, reason: 'novelPlacement' }, null, false, now, time),
    {
      stage: 'pinned',
      text: 'fleet → primary · novelPlacement',
      tone: 'neutral',
    },
  )
  assertEquals(
    routeNote(
      { ...pinned, reason: 'lastResort:solarFlare', previousMember: 'backup' },
      null,
      false,
      now,
      time,
    ),
    {
      stage: 'switched',
      text: 'fleet → primary · switched from backup after solarFlare',
      tone: 'neutral',
    },
  )
})

Deno.test('the server inspection fixture decodes to the failure it encodes', async () => {
  const fixture = JSON.parse(
    await Deno.readTextFile(
      new URL('./model-route-inspection.gen.json', import.meta.url),
    ),
  )
  const failure = routeFailureOf(fixture)
  assertEquals(failure, {
    reason: 'quota',
    source: 'upstream',
    code: 'refusal',
    deadline: new Date('2026-10-03T04:40:00Z'),
    retryAt: new Date('2026-10-03T05:10:00Z'),
  })
  const deadline = failure!.deadline!
  assertEquals(
    routeNote(waiting, failure, false, deadline, time).stage,
    'blocked',
  )
  assertEquals(
    routeNote(waiting, failure, false, new Date(deadline.getTime() - 1), time)
      .stage,
    'waiting',
  )
})

Deno.test('a roster without routes keeps every concrete session as it is', () => {
  const rows = [{ id: 's1', title: 'a' }, { id: 's2', title: 'b' }]
  assertEquals(withRoutes(rows, new Map()), rows)
  assertEquals(withRoutes(rows, new Map([['s2', pinned]]))?.[1], {
    id: 's2',
    title: 'b',
    route: pinned,
  })
  assertEquals(withRoutes(null, new Map()), null)
})
