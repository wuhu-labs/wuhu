import { assertEquals, assertRejects, assertThrows } from 'jsr:@std/assert@1'
import {
  createSpace,
  failure,
  type FileEvent,
  type Snapshot,
  SpaceError,
  type Stream,
  type Transport,
} from './shell-sdk/space-core.js'

const stream = <T>(values: T[], closed: string[], name: string): Stream<T> => ({
  next: () => Promise.resolve(values.shift() ?? null),
  close: () => closed.push(name),
})

function fake(snapshots: Snapshot[] = []) {
  const calls: unknown[] = []
  const closed: string[] = []
  const transport: Transport = {
    query(sql, params) {
      calls.push({ query: sql, params })
      return Promise.resolve(snapshots.shift()!)
    },
    observe(sql, params) {
      calls.push({ observe: sql, params })
      return stream([...snapshots], closed, 'observe')
    },
    watch(glob, from) {
      calls.push({ watch: glob, from })
      const events: FileEvent[] = [
        { kind: 'write', path: '/a.md', rev: 3, entry: 'file' },
        { kind: 'delete', path: '/b.md', rev: 4 },
      ]
      return stream(events, closed, 'watch')
    },
    mutateRows(path, ops) {
      calls.push({ mutateRows: path, ops })
      return Promise.resolve({ rev: 9, ids: [5] })
    },
    readAttributes(path) {
      calls.push({ readAttributes: path })
      return Promise.resolve({ attributes: { a: 1 }, token: 't1' })
    },
    patchAttributes(path, patch) {
      calls.push({ patchAttributes: path, patch })
      return Promise.reject(
        failure({ code: 'conflict', message: 'stale', token: 't2' }),
      )
    },
  }
  return { space: createSpace(transport), calls, closed }
}

Deno.test('query binds interpolations and resolves typed rows', async () => {
  const { space, calls } = fake([{
    columns: ['n', 'meta', 'data', 'done'],
    rows: [[1, { json: { k: [1] } }, { blob: 'AQc=' }, true]],
  }])
  const when = new Date('2026-09-28T00:00:00.000Z')
  const rows = await space
    .query`SELECT * FROM t WHERE a = ${'x'} AND b = ${2n} AND c = ${when} AND d = ${new Uint8Array(
    [1, 7],
  )} AND e = ${null}`
  assertEquals(calls, [{
    query:
      'SELECT * FROM t WHERE a = ? AND b = ? AND c = ? AND d = ? AND e = ?',
    params: ['x', 2, '2026-09-28T00:00:00.000Z', { blob: 'AQc=' }, null],
  }])
  assertEquals(rows, [{
    n: 1,
    meta: { k: [1] },
    data: new Uint8Array([1, 7]),
    done: true,
  }])
})

Deno.test('query takes a SQL string with a params array', async () => {
  const { space, calls } = fake([{ columns: [], rows: [] }])
  assertEquals(await space.query('SELECT ?', [true]), [])
  assertEquals(calls, [{ query: 'SELECT ?', params: [true] }])
  await assertRejects(() => space.query('SELECT ?', 1 as never), TypeError)
  await assertRejects(() => space.query('SELECT ?', [{}]), TypeError)
  await assertRejects(() => space.query('SELECT ?', [NaN]), TypeError)
  await assertRejects(
    () => space.query('SELECT ?', [2n ** 60n]),
    TypeError,
    'safe integer',
  )
})

Deno.test('observe opens on iteration and closes when the loop is left', async () => {
  const { space, calls, closed } = fake([
    { columns: ['n'], rows: [[1]] },
    { columns: ['n'], rows: [[2]] },
  ])
  const snapshots = space.observe`SELECT n FROM t WHERE x = ${1}`
  assertEquals(calls, [])
  const seen = []
  for await (const rows of snapshots) {
    seen.push(rows)
    if (seen.length === 2) break
  }
  assertEquals(seen, [[{ n: 1 }], [{ n: 2 }]])
  assertEquals(calls, [{ observe: 'SELECT n FROM t WHERE x = ?', params: [1] }])
  assertEquals(closed, ['observe'])
})

Deno.test('watch passes from and closes once the stream ends', async () => {
  const { space, calls, closed } = fake()
  const events = []
  for await (const event of space.watch('/notes/**', { from: 2n })) {
    events.push(event.kind)
  }
  assertEquals(events, ['write', 'delete'])
  assertEquals(calls, [{ watch: '/notes/**', from: 2 }])
  assertEquals(closed, ['watch'])
  assertThrows(() => space.watch(''), TypeError)
  assertThrows(() => space.watch('/x', { from: 1.5 }), TypeError)
})

Deno.test('mutateRows sends named ops with typed fields', async () => {
  const { space, calls } = fake()
  const result = await space.mutateRows('/tasks.table', [
    {
      insert: {
        title: 'a',
        meta: { tags: ['x'] },
        list: [1],
        data: new Uint8Array([255]),
        skipped: undefined,
      },
    },
    { update: 3n, set: { done: true, at: new Date(0) } },
    { delete: 4 },
  ])
  assertEquals(result, { rev: 9, ids: [5] })
  assertEquals(calls, [{
    mutateRows: '/tasks.table',
    ops: [
      {
        insert: {
          title: 'a',
          meta: { json: { tags: ['x'] } },
          list: { json: [1] },
          data: { blob: '/w==' },
        },
      },
      { update: 3, set: { done: true, at: '1970-01-01T00:00:00.000Z' } },
      { delete: 4 },
    ],
  }])
})

Deno.test('mutateRows refuses malformed ops before sending', async () => {
  const { space, calls } = fake()
  const refused = [
    [{ insert: {}, delete: 1 }],
    [{ upsert: {} }],
    [{ update: 1.5, set: {} }],
    [{ update: 1 }],
    [{ insert: { at: new Map() } }],
    [{ delete: '1' }],
  ]
  for (const ops of refused) {
    await assertRejects(
      () => space.mutateRows('/t.table', ops as never),
      TypeError,
    )
  }
  await assertRejects(() => space.mutateRows('', []), TypeError)
  await assertRejects(
    () => space.mutateRows('/t.table', {} as never),
    TypeError,
  )
  assertEquals(calls, [])
})

Deno.test('patchAttributes needs ifMatch and rejects as a SpaceError', async () => {
  const { space, calls } = fake()
  assertEquals(await space.readAttributes('/plan.md'), {
    attributes: { a: 1 },
    token: 't1',
  })
  await assertRejects(
    () => space.patchAttributes('/plan.md', { set: { a: 2 } } as never),
    TypeError,
    'ifMatch',
  )
  await assertRejects(
    () =>
      space.patchAttributes('/plan.md', {
        set: { a: undefined },
        ifMatch: 't1',
      }),
    TypeError,
    'remove',
  )
  const error = await assertRejects(
    () =>
      space.patchAttributes('/plan.md', {
        set: { status: 'done', at: new Date(0) },
        remove: ['draft'],
        ifMatch: 't1',
      }),
    SpaceError,
    'stale',
  )
  assertEquals([error.code, error.token], ['conflict', 't2'])
  assertEquals(calls.at(-1), {
    patchAttributes: '/plan.md',
    patch: {
      set: { status: 'done', at: '1970-01-01T00:00:00.000Z' },
      remove: ['draft'],
      ifMatch: 't1',
    },
  })
})

Deno.test('failure falls back for a body without a code', () => {
  const error = failure('oops', 'HTTP 502')
  assertEquals([error.name, error.code, error.message], [
    'SpaceError',
    'internal',
    'HTTP 502',
  ])
  const hinted = failure({ code: 'notFound', message: 'gone', hint: 'ls' })
  assertEquals([hinted.code, hinted.hint, hinted.token], [
    'notFound',
    'ls',
    undefined,
  ])
})
