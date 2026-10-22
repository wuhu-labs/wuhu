import { routeRows, type SessionRoute, withRoutes } from './model-route.ts'

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

const pinned: SessionRoute = {
  group: 'fleet',
  member: 'primary',
  phase: 'pinned',
  epoch: '3',
  reason: 'create',
  previousMember: null,
  failureRevision: null,
}

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
