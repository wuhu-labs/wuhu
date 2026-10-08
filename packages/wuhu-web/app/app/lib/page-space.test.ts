import { assertEquals, assertRejects } from 'jsr:@std/assert@1'
import {
  fetch as spaceFetch,
  mutateRows,
  observe,
  patchAttributes,
  query,
  readAttributes,
  SpaceError,
  watch,
} from './shell-sdk/space.js'

const origin = 'https://home.space.test:5531'

interface Sent {
  url: URL
  init?: RequestInit
}

// The page's origin and path, and a network that answers each request in turn.
function page(answers: (() => Response | Promise<Response>)[]) {
  const sent: Sent[] = []
  Object.defineProperty(globalThis, 'location', {
    configurable: true,
    value: { origin, pathname: '/apps/tasks.html' },
  })
  globalThis.fetch = (input: RequestInfo | URL, init?: RequestInit) => {
    sent.push({ url: new URL(String(input)), init })
    return Promise.resolve(answers.shift()!())
  }
  return sent
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  })

const events = (...data: unknown[]) =>
  new Response(
    data.map((value) => `data: ${JSON.stringify(value)}\n\n`).join(''),
    { headers: { 'content-type': 'text/event-stream' } },
  )

Deno.test('query sends its statement and bound parameters, and omits empty ones', async () => {
  const sent = page([
    () => json({ columns: ['title', 'n'], rows: [['Ship', 2]] }),
    () => json({ columns: ['n'], rows: [[1]] }),
  ])
  assertEquals(
    await query`SELECT title, n FROM "/tasks.table" WHERE status = ${'done'}`,
    [{ title: 'Ship', n: 2 }],
  )
  assertEquals(await query('SELECT 1 AS n'), [{ n: 1 }])
  assertEquals(
    sent[0]!.url.origin + sent[0]!.url.pathname,
    `${origin}/_/space/query`,
  )
  assertEquals(
    sent[0]!.url.searchParams.get('sql'),
    'SELECT title, n FROM "/tasks.table" WHERE status = ?',
  )
  assertEquals(sent[0]!.url.searchParams.get('params'), '["done"]')
  // Spaces go as %20: the server reads a `+` as itself.
  assertEquals(sent[1]!.url.search, '?sql=SELECT%201%20AS%20n')
})

Deno.test('writes post JSON naming the page, and read attributes by path', async () => {
  const sent = page([
    () => json({ rev: 7, ids: [3] }),
    () => json({ attributes: { status: 'todo' }, token: 't1' }),
    () => json({ token: 't2' }),
  ])
  assertEquals(
    await mutateRows('/tasks.table', [{ insert: { title: 'Ship' } }]),
    { rev: 7, ids: [3] },
  )
  const { token } = await readAttributes('/notes/plan.md')
  assertEquals(
    await patchAttributes('/notes/plan.md', {
      set: { status: 'done' },
      remove: ['draft'],
      ifMatch: token,
    }),
    { token: 't2' },
  )
  assertEquals(sent[0]!.url.href, `${origin}/_/space/rows`)
  assertEquals(sent[0]!.init!.method, 'POST')
  assertEquals(sent[0]!.init!.headers, { 'content-type': 'application/json' })
  assertEquals(JSON.parse(sent[0]!.init!.body as string), {
    path: '/tasks.table',
    ops: [{ insert: { title: 'Ship' } }],
    page: '/apps/tasks.html',
  })
  assertEquals(
    sent[1]!.url.href,
    `${origin}/_/space/attributes?path=%2Fnotes%2Fplan.md`,
  )
  assertEquals(sent[2]!.url.href, `${origin}/_/space/attributes`)
  assertEquals(JSON.parse(sent[2]!.init!.body as string), {
    path: '/notes/plan.md',
    set: { status: 'done' },
    remove: ['draft'],
    ifMatch: 't1',
    page: '/apps/tasks.html',
  })
})

Deno.test('an error status rejects with its SpaceError, a conflict with the current token', async () => {
  page([
    () =>
      json({ code: 'conflict', message: 'version mismatch', token: 't9' }, 409),
  ])
  const error = await assertRejects(
    () => patchAttributes('/notes/plan.md', { ifMatch: 't1' }),
    SpaceError,
  )
  assertEquals([error.code, error.token], ['conflict', 't9'])
})

Deno.test("a status without an explained body is internal, and a network failure is fetch's own", async () => {
  page([
    () => new Response('Bad Gateway', { status: 502 }),
    () => Promise.reject(new TypeError('Failed to fetch')),
  ])
  const error = await assertRejects(
    () => mutateRows('/tasks.table', []),
    SpaceError,
  )
  assertEquals([error.code, error.message], ['internal', 'HTTP 502'])
  await assertRejects(() => query('SELECT 1'), TypeError, 'Failed to fetch')
})

Deno.test('observe yields each snapshot as rows, and an error status ends it', async () => {
  const sent = page([
    () =>
      events(
        { columns: ['title'], rows: [] },
        { columns: ['title'], rows: [['Ship']] },
      ),
    () => json({ code: 'notFound', message: 'no such table' }, 404),
  ])
  const snapshots: unknown[] = []
  const error = await assertRejects(async () => {
    for await (
      const rows of observe`SELECT title FROM "/tasks.table" WHERE n > ${1}`
    ) {
      snapshots.push(rows)
      if (snapshots.length === 2) break
    }
    for await (const _ of observe('SELECT nope FROM "/missing.table"'));
  }, SpaceError)
  assertEquals(snapshots, [[], [{ title: 'Ship' }]])
  assertEquals(error.code, 'notFound')
  assertEquals(sent[0]!.url.pathname, '/_/space/observe')
  assertEquals(sent[0]!.url.searchParams.get('params'), '[1]')
})

Deno.test('watch reconnects after a dropped stream, resuming after the last event', async () => {
  const write = (rev: number) => ({
    kind: 'write',
    path: '/notes/plan.md',
    rev,
  })
  const sent = page([
    () => events(write(5), write(6)),
    () => events(write(9)),
  ])
  const seen: number[] = []
  for await (const event of watch('/notes/**', { from: 4 })) {
    seen.push(event.rev)
    if (seen.length === 3) break
  }
  assertEquals(seen, [5, 6, 9])
  assertEquals(
    sent.map(({ url }) => url.search),
    ['?glob=%2Fnotes%2F**&from=4', '?glob=%2Fnotes%2F**&from=6'],
  )
})

Deno.test('a watch opened without from resumes after its head frame when it drops before any event', async () => {
  const sent = page([
    () =>
      new Response('event: head\ndata: {"rev":7}\n\n', {
        headers: { 'content-type': 'text/event-stream' },
      }),
    () => events({ kind: 'write', path: '/notes/plan.md', rev: 8 }),
  ])
  for await (const event of watch('/notes/**')) {
    assertEquals(event.rev, 8)
    break
  }
  assertEquals(
    sent.map(({ url }) => url.search),
    ['?glob=%2Fnotes%2F**', '?glob=%2Fnotes%2F**&from=7'],
  )
})

Deno.test('proxied fetch preserves body, target headers, upstream errors and streaming Response', async () => {
  const upstream = new Response('backend says no', {
    status: 422,
    headers: { 'wuhu-fetch-result': 'upstream', 'x-backend': 'yes' },
  })
  const sent = page([() => upstream])
  const response = await spaceFetch('https://dash.test/q', {
    method: 'POST',
    headers: { 'content-type': 'text/plain', 'x-query': 'test' },
    body: 'select 1',
  })
  assertEquals(response, upstream)
  assertEquals(response.status, 422)
  assertEquals(await response.text(), 'backend says no')
  assertEquals(sent[0]!.url.pathname, '/_/space/fetch')
  assertEquals(sent[0]!.url.searchParams.get('url'), 'https://dash.test/q')
  assertEquals(sent[0]!.url.searchParams.get('method'), 'POST')
  assertEquals(sent[0]!.url.searchParams.get('page'), '/apps/tasks.html')
  assertEquals(JSON.parse(sent[0]!.url.searchParams.get('headers')!), {
    'content-type': 'text/plain',
    'x-query': 'test',
  })
  assertEquals(
    new TextDecoder().decode(sent[0]!.init!.body as ArrayBuffer),
    'select 1',
  )
  assertEquals(sent[0]!.init!.credentials, 'same-origin')
})

Deno.test('proxied fetch refusals are SpaceError and Authorization never makes a request', async () => {
  const sent = page([
    () =>
      json(
        { code: 'fetchListMissing', message: '/fetch.json is missing' },
        403,
      ),
  ])
  const denied = await assertRejects(
    () => spaceFetch('https://dash.test'),
    SpaceError,
  )
  assertEquals((denied as SpaceError).code, 'fetchListMissing')
  assertEquals(denied.message, '/fetch.json is missing')
  const authorization = await assertRejects(
    () =>
      spaceFetch('https://dash.test', { headers: { Authorization: 'secret' } }),
    SpaceError,
  )
  assertEquals(
    (authorization as SpaceError).code,
    'fetchAuthorizationForbidden',
  )
  assertEquals(sent.length, 1)
})

Deno.test('proxied fetch accepts Request input and propagates cancellation', async () => {
  const sent = page([
    () => new Response(null, { headers: { 'wuhu-fetch-result': 'upstream' } }),
  ])
  const controller = new AbortController()
  await spaceFetch(
    new Request('https://dash.test', {
      method: 'HEAD',
      signal: controller.signal,
    }),
  )
  assertEquals(sent[0]!.url.searchParams.get('method'), 'HEAD')
  controller.abort()
  assertEquals(sent[0]!.init!.signal!.aborted, true)
})

Deno.test('abort cancels an open streaming request body before any native fetch', async () => {
  const sent = page([])
  let cancelled = false
  const controller = new AbortController()
  const init = {
    method: 'POST',
    signal: controller.signal,
    duplex: 'half',
    body: new ReadableStream<Uint8Array>({
      start(stream) {
        stream.enqueue(new Uint8Array([1]))
      },
      cancel() {
        cancelled = true
      },
    }),
  }
  const pending = spaceFetch(new Request('https://dash.test/q', init))
  controller.abort()
  const error = await assertRejects(() => pending, DOMException)
  assertEquals(error.name, 'AbortError')
  assertEquals(cancelled, true)
  assertEquals(sent.length, 0)
})
