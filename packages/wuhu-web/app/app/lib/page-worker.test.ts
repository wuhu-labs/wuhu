import { assertEquals } from 'jsr:@std/assert@1'
import {
  type CacheKind,
  type CacheScope,
  evictions,
  normalizeSQL,
  scopeKey,
} from './shell-sdk/open-cache.js'
import {
  cookieViewer,
  freshMessage,
  pageWorker,
  unauthorizedMessage,
} from './shell-sdk/worker.js'

const origin = 'https://space.test:5531'

class MemoryCache {
  readonly entries = new Map<string, unknown>()
  readonly puts: string[] = []
  readonly purged: string[] = []
  private id(scope: CacheScope, kind: CacheKind, key: string) {
    return `${scopeKey(scope)}\n${kind}\n${key}`
  }
  get(scope: CacheScope, kind: CacheKind, key: string) {
    return Promise.resolve(this.entries.get(this.id(scope, kind, key)))
  }
  put(scope: CacheScope, kind: CacheKind, key: string, value: unknown) {
    if (kind !== 'meta') this.puts.push(`${scope.viewer} ${kind} ${key}`)
    this.entries.set(this.id(scope, kind, key), value)
    return Promise.resolve()
  }
  purge(scope: CacheScope, kind?: CacheKind) {
    this.purged.push(
      kind === undefined ? scope.viewer : `${scope.viewer} ${kind}`,
    )
    const prefix = `${scopeKey(scope)}\n${
      kind === undefined ? '' : `${kind}\n`
    }`
    for (const id of [...this.entries.keys()]) {
      if (id.startsWith(prefix)) this.entries.delete(id)
    }
    return Promise.resolve()
  }
  seed(viewer: string, kind: CacheKind, key: string, value: unknown) {
    const scope = { space: origin, group: 'shared', viewer }
    this.entries.set(this.id(scope, kind, key), value)
    this.entries.set(
      this.id({ space: origin, group: '', viewer: '' }, 'meta', 'viewer'),
      viewer,
    )
  }
  kept(viewer: string, kind: CacheKind, key: string) {
    const scope = { space: origin, group: 'shared', viewer }
    return this.entries.get(this.id(scope, kind, key))
  }
}

interface Sent {
  input: Request | string
  url: string
  headers: Headers
  signal?: AbortSignal
}

function network(
  answer: (url: string, headers: Headers) => Response | Promise<Response>,
) {
  const sent: Sent[] = []
  const fetch = (input: Request | string, init?: RequestInit) => {
    const url = typeof input === 'string' ? input : input.url
    const headers = new Headers(
      init?.headers ?? (typeof input === 'string' ? {} : input.headers),
    )
    sent.push({ input, url, headers, signal: init?.signal ?? undefined })
    return Promise.resolve(answer(url, headers))
  }
  return { sent, fetch }
}

function viewed(
  body: BodyInit | null,
  init: ResponseInit & { viewer?: string },
) {
  const headers = new Headers(init.headers)
  if (init.viewer !== undefined) headers.set('wuhu-viewer', init.viewer)
  return new Response(body, { status: init.status ?? 200, headers })
}

function request(path: string, mode: RequestMode = 'cors'): Request {
  return { url: origin + path, method: 'GET', mode } as Request
}

function events() {
  const pending: Promise<unknown>[] = []
  const notes: unknown[] = []
  return {
    waitUntil: (promise: Promise<unknown>) => void pending.push(promise),
    notify: (message: unknown) => void notes.push(message),
    settled: () => Promise.all(pending),
    notes,
  }
}

const as = (viewer: string) => () => Promise.resolve(viewer)
const tick = () => new Promise((resolve) => setTimeout(resolve, 0))

function controlled() {
  let controller!: ReadableStreamDefaultController<Uint8Array>
  const body = new ReadableStream<Uint8Array>({
    start(started) {
      controller = started
    },
  })
  return { body, controller }
}

const encoder = new TextEncoder()
const sql = 'SELECT  title\n  FROM "/tasks.table"'
const key = normalizeSQL(sql)
const queryPath = `/_/query?sql=${encodeURIComponent(sql)}`
const observePath = `/_/observe?sql=${encodeURIComponent(sql)}`
const snapshot = (rows: string) => ({
  body: `{"rows":[["${rows}"]]}`,
  type: 'application/json',
  etag: null,
})
const eventStream = { 'content-type': 'text/event-stream' }

Deno.test('normalizeSQL collapses whitespace outside quotes only', () => {
  assertEquals(key, 'SELECT title FROM "/tasks.table"')
  assertEquals(
    normalizeSQL(' SELECT \'a   b\'\n,  "c  d" '),
    'SELECT \'a   b\' , "c  d"',
  )
})

Deno.test('eviction drops least recently used entries until the incoming one fits', () => {
  const entries = [
    { id: 'recent', bytes: 40, used: 30 },
    { id: 'oldest', bytes: 40, used: 10 },
    { id: 'middle', bytes: 40, used: 20 },
  ]
  assertEquals(evictions(entries, { id: 'new', bytes: 30 }, 150), [])
  assertEquals(evictions(entries, { id: 'new', bytes: 30 }, 120), ['oldest'])
  assertEquals(evictions(entries, { id: 'new', bytes: 60 }, 100), [
    'oldest',
    'middle',
  ])
  // A replaced entry's old bytes do not count against its new ones.
  assertEquals(evictions(entries, { id: 'recent', bytes: 80 }, 160), [])
})

Deno.test('an entry larger than its budget is refused before anything is evicted', () => {
  const entries = [{ id: 'kept', bytes: 40, used: 10 }]
  assertEquals(evictions(entries, { id: 'huge', bytes: 101 }, 100), null)
  assertEquals(evictions(entries, { id: 'page', bytes: 1 }, undefined), null)
})

Deno.test('observe emits the cached snapshot first, then the live stream, keeping each snapshot', async () => {
  const cache = new MemoryCache()
  cache.seed('alice', 'query', key, snapshot('kept'))
  const live = controlled()
  const { fetch } = network(() =>
    viewed(live.body, { headers: eventStream, viewer: 'alice' })
  )
  const worker = pageWorker({ cache, fetch, origin, viewer: as('alice') })
  const response = await worker.respond(request(observePath), events())!
  assertEquals(response.headers.get('content-type'), 'text/event-stream')
  const reader = response.body!.pipeThrough(new TextDecoderStream())
    .getReader()
  assertEquals((await reader.read()).value, 'data: {"rows":[["kept"]]}\n\n')

  live.controller.enqueue(
    encoder.encode(': heartbeat\n\ndata: {"rows":[["live"]]}\n\n'),
  )
  assertEquals(
    (await reader.read()).value,
    ': heartbeat\n\ndata: {"rows":[["live"]]}\n\n',
  )
  await tick()
  assertEquals(cache.kept('alice', 'query', key), snapshot('live'))
  live.controller.close()
  assertEquals((await reader.read()).done, true)
})

Deno.test('cancelling the page stream aborts the upstream fetch', async () => {
  const cache = new MemoryCache()
  cache.seed('alice', 'query', key, snapshot('kept'))
  const { sent, fetch } = network(() =>
    viewed(controlled().body, { headers: eventStream, viewer: 'alice' })
  )
  const worker = pageWorker({ cache, fetch, origin, viewer: as('alice') })
  const response = await worker.respond(request(observePath), events())!
  const reader = response.body!.getReader()
  await reader.read()
  await tick()
  assertEquals(sent[0]!.signal!.aborted, false)
  await reader.cancel()
  assertEquals(sent[0]!.signal!.aborted, true)
})

Deno.test('a refused live answer on the cached path reaches the page on its reconnect', async () => {
  const cache = new MemoryCache()
  cache.seed('alice', 'query', key, snapshot('kept'))
  const { sent, fetch } = network(() =>
    viewed('{"error":"unauthorized"}', { status: 401 })
  )
  const worker = pageWorker({ cache, fetch, origin, viewer: as('alice') })
  const first = events()
  const cached = await worker.respond(request(observePath), first)!
  assertEquals(await cached.text(), 'data: {"rows":[["kept"]]}\n\n')
  assertEquals(first.notes, [unauthorizedMessage])

  const reconnect = await worker.respond(request(observePath), events())!
  assertEquals(reconnect.status, 401)
  assertEquals(sent.length, 2)
  // Only the one reconnect skips the snapshot.
  const later = await worker.respond(request(observePath), events())!
  assertEquals(later.status, 200)
})

Deno.test('observe with nothing cached passes the live stream through and keeps it', async () => {
  const cache = new MemoryCache()
  const { fetch } = network(() =>
    viewed('data: {"rows":[]}\n\n', { headers: eventStream, viewer: 'alice' })
  )
  const worker = pageWorker({ cache, fetch, origin, viewer: as('alice') })
  const response = await worker.respond(request(observePath), events())!
  assertEquals(await response.text(), 'data: {"rows":[]}\n\n')
  assertEquals(cache.puts, [`alice query ${key}`])
})

Deno.test('an unreachable space ends the cached observe stream after its snapshot', async () => {
  const cache = new MemoryCache()
  cache.seed('alice', 'query', key, snapshot('kept'))
  const worker = pageWorker({
    cache,
    fetch: () => Promise.reject(new TypeError('offline')),
    origin,
    viewer: as('alice'),
  })
  const response = await worker.respond(request(observePath), events())!
  assertEquals(await response.text(), 'data: {"rows":[["kept"]]}\n\n')
})

Deno.test('a query answers from cache and revalidates with its tag', async () => {
  const cache = new MemoryCache()
  cache.seed('alice', 'query', key, { ...snapshot('old'), etag: '"old"' })
  let fresh = false
  const { sent, fetch } = network(() =>
    fresh
      ? viewed('{"rows":[["new"]]}', {
        headers: { 'content-type': 'application/json', etag: '"new"' },
        viewer: 'alice',
      })
      : viewed(null, { status: 304, headers: { etag: '"old"' } })
  )
  const worker = pageWorker({ cache, fetch, origin, viewer: as('alice') })

  const first = events()
  const unchanged = await worker.respond(request(queryPath), first)!
  assertEquals(await unchanged.text(), '{"rows":[["old"]]}')
  await first.settled()
  assertEquals(sent[0]!.headers.get('if-none-match'), '"old"')
  assertEquals(cache.puts, [])

  fresh = true
  const second = events()
  const stale = await worker.respond(request(queryPath), second)!
  assertEquals(await stale.text(), '{"rows":[["old"]]}')
  await second.settled()
  assertEquals(cache.kept('alice', 'query', key), {
    ...snapshot('new'),
    etag: '"new"',
  })
  const third = await worker.respond(request(queryPath), events())!
  assertEquals(await third.text(), '{"rows":[["new"]]}')
})

Deno.test('a first page visit streams while it is stored', async () => {
  const cache = new MemoryCache()
  const live = controlled()
  const { fetch } = network(() =>
    viewed(live.body, {
      headers: { 'content-type': 'text/html', etag: '"1"' },
      viewer: 'alice',
    })
  )
  const worker = pageWorker({ cache, fetch, origin, viewer: as('alice') })
  const visit = events()
  const response = await worker.respond(request('/notes/', 'navigate'), visit)!
  const reader = response.body!.pipeThrough(new TextDecoderStream())
    .getReader()
  live.controller.enqueue(encoder.encode('<p>one'))
  assertEquals((await reader.read()).value, '<p>one')
  live.controller.enqueue(encoder.encode('</p>'))
  live.controller.close()
  await visit.settled()
  assertEquals(cache.kept('alice', 'page', '/notes/'), {
    body: '<p>one</p>',
    type: 'text/html',
    etag: '"1"',
  })
})

Deno.test('a cached page paints at once and tells the page when fresh HTML replaced it', async () => {
  const cache = new MemoryCache()
  cache.seed('alice', 'page', '/notes/', {
    body: '<p>one</p>',
    type: 'text/html',
    etag: '"1"',
  })
  const body = '<p>two</p>'
  const { fetch } = network((_, headers) =>
    headers.get('if-none-match') === `"${body}"`
      ? viewed(null, { status: 304, viewer: 'alice' })
      : viewed(body, {
        headers: { 'content-type': 'text/html', etag: `"${body}"` },
        viewer: 'alice',
      })
  )
  const worker = pageWorker({ cache, fetch, origin, viewer: as('alice') })
  const changed = events()
  const stale = await worker.respond(request('/notes/', 'navigate'), changed)!
  assertEquals(await stale.text(), '<p>one</p>')
  await changed.settled()
  assertEquals(changed.notes, [freshMessage])

  const reload = events()
  const fresh = await worker.respond(request('/notes/', 'navigate'), reload)!
  assertEquals(await fresh.text(), '<p>two</p>')
  await reload.settled()
  assertEquals(reload.notes, [])
})

Deno.test('a cached group-host page keeps its frame-ancestors, so no sibling can frame the copy', async () => {
  const csp = "frame-ancestors 'self' https://alice.space.test:5530"
  const cache = new MemoryCache()
  let answer: () => Response | Promise<Response> = () =>
    viewed('<p>one</p>', {
      headers: {
        'content-type': 'text/html',
        etag: '"1"',
        'content-security-policy': csp,
      },
      viewer: 'alice',
    })
  const { fetch } = network(() => answer())
  const worker = pageWorker({ cache, fetch, origin, viewer: as('alice') })

  const first = events()
  const live = await worker.respond(request('/notes.html', 'navigate'), first)!
  assertEquals(live.headers.get('content-security-policy'), csp)
  await live.text()
  await first.settled()
  assertEquals(cache.kept('alice', 'page', '/notes.html'), {
    body: '<p>one</p>',
    type: 'text/html',
    etag: '"1"',
    csp,
  })

  // Offline, the framed navigation paints the kept copy, policy included.
  answer = () => Promise.reject(new TypeError('offline'))
  const framed = events()
  const cached = await worker.respond(
    request('/notes.html', 'navigate'),
    framed,
  )!
  assertEquals(await cached.text(), '<p>one</p>')
  assertEquals(cached.headers.get('content-security-policy'), csp)
  await framed.settled()
})

Deno.test('a page served without a policy is replayed without one', async () => {
  const cache = new MemoryCache()
  cache.seed('alice', 'page', '/notes/', {
    body: '<p>one</p>',
    type: 'text/html',
    etag: '"1"',
  })
  const { fetch } = network(() =>
    viewed(null, { status: 304, viewer: 'alice' })
  )
  const worker = pageWorker({ cache, fetch, origin, viewer: as('alice') })
  const visit = events()
  const cached = await worker.respond(request('/notes/', 'navigate'), visit)!
  assertEquals(cached.headers.get('content-security-policy'), null)
  assertEquals(cached.headers.get('content-type'), 'text/html')
  await visit.settled()
})

Deno.test('entries are read as the cookie viewer and written as Wuhu-Viewer; a changed viewer purges the previous one', async () => {
  const cache = new MemoryCache()
  cache.seed('alice', 'page', '/', {
    body: '<p>alice</p>',
    type: 'text/html',
    etag: null,
  })
  let viewer = 'bob'
  const { fetch } = network(() =>
    viewer === ''
      ? viewed('{"error":"unauthorized"}', { status: 401 })
      : viewed('<p>bob</p>', {
        headers: { 'content-type': 'text/html' },
        viewer: 'bob',
      })
  )
  const worker = pageWorker({
    cache,
    fetch,
    origin,
    viewer: () => Promise.resolve(viewer),
  })
  const visit = events()
  const page = await worker.respond(request('/', 'navigate'), visit)!
  assertEquals(await page.text(), '<p>bob</p>')
  await visit.settled()
  assertEquals(cache.purged, ['alice'])
  assertEquals(cache.kept('alice', 'page', '/'), undefined)
  assertEquals(cache.kept('bob', 'page', '/'), {
    body: '<p>bob</p>',
    type: 'text/html',
    etag: null,
  })

  // Signing out clears the cookie; the next request purges what bob kept.
  viewer = ''
  await (await worker.respond(request('/', 'navigate'), events())!).text()
  assertEquals(cache.purged, ['alice', 'bob'])
  assertEquals(cache.kept('bob', 'page', '/'), undefined)
})

Deno.test('a failing cache is a miss, and the network still answers', async () => {
  const failing = {
    get: () => Promise.reject(new Error('closed')),
    put: () => Promise.reject(new Error('closed')),
    purge: () => Promise.reject(new Error('closed')),
  }
  const { fetch } = network(() =>
    viewed('{"rows":[]}', {
      headers: { 'content-type': 'application/json' },
      viewer: 'alice',
    })
  )
  const worker = pageWorker({
    cache: failing,
    fetch,
    origin,
    viewer: as('alice'),
  })
  const visit = events()
  const response = await worker.respond(request(queryPath), visit)!
  assertEquals(await response.text(), '{"rows":[]}')
  await visit.settled()
})

Deno.test('product chrome and other origins are never stored', async () => {
  const cache = new MemoryCache()
  const { sent, fetch } = network((url) =>
    viewed('x', {
      headers: {
        'content-type': url.endsWith('.js') ? 'text/javascript' : 'text/html',
      },
    })
  )
  const worker = pageWorker({ cache, fetch, origin, viewer: as('alice') })
  for (
    const path of [
      '/_/shell.js',
      '/_/worker.js',
      '/_/open-cache.js',
      '/_/views/list?path=%2Fa.view&rev=1',
      '/_/assets/index-abc.js',
      '/photo.png',
    ]
  ) {
    const mode = path.startsWith('/_/views/') ? 'navigate' : 'cors'
    await (await worker.respond(request(path, mode), events()))!.text()
  }
  assertEquals(cache.puts, [])
  assertEquals(sent.length, 6)
  assertEquals(
    worker.respond(
      { url: 'https://app.test/_/assets/x.js', method: 'GET' } as Request,
      events(),
    ),
    null,
  )
})

const typedSQL = 'SELECT title FROM "/tasks.table" WHERE status = ?'
const typedPath = (route: string, params: string) =>
  `/_/space/${route}?sql=${encodeURIComponent(typedSQL)}&params=${
    encodeURIComponent(params)
  }`
const typedKey = (params: string) => `space\n${typedSQL}\n${params}`
const typed = (title: string) => `{"columns":["title"],"rows":[["${title}"]]}`
const jsonType = { 'content-type': 'application/json' }

function write(path: string, body: unknown): Request {
  return new Request(origin + path, {
    method: 'POST',
    headers: jsonType,
    body: JSON.stringify(body),
  })
}

Deno.test('a typed statement is kept under its parameters, apart from its legacy form', async () => {
  const cache = new MemoryCache()
  cache.seed('alice', 'query', key, snapshot('legacy'))
  const { sent, fetch } = network(() =>
    viewed(typed('fresh'), { headers: jsonType, viewer: 'alice' })
  )
  const worker = pageWorker({ cache, fetch, origin, viewer: as('alice') })
  const first = events()
  const query = await worker.respond(
    request(typedPath('query', '["done"]')),
    first,
  )!
  assertEquals(await query.text(), typed('fresh'))
  await first.settled()
  assertEquals(cache.puts, [`alice query ${typedKey('["done"]')}`])

  const observed = await worker.respond(
    request(typedPath('observe', '["done"]')),
    events(),
  )!
  const reader = observed.body!.pipeThrough(new TextDecoderStream())
    .getReader()
  assertEquals((await reader.read()).value, `data: ${typed('fresh')}\n\n`)
  await reader.cancel()

  const other = events()
  await (await worker.respond(request(typedPath('query', '["todo"]')), other)!)
    .text()
  await other.settled()
  assertEquals(sent.length, 3)
  assertEquals(cache.kept('alice', 'query', key), snapshot('legacy'))
})

Deno.test('a committed write passes through and drops the query results its viewer kept, not its pages', async () => {
  const cache = new MemoryCache()
  cache.seed('alice', 'query', key, snapshot('kept'))
  cache.seed('alice', 'query', typedKey('["done"]'), snapshot('kept'))
  cache.seed('alice', 'page', '/apps/tasks.html', {
    body: '<p>tasks</p>',
    type: 'text/html',
    etag: null,
  })
  let status = 409
  const { sent, fetch } = network(() =>
    viewed('{"code":"conflict","message":"stale"}', {
      status,
      headers: jsonType,
      viewer: 'alice',
    })
  )
  const worker = pageWorker({ cache, fetch, origin, viewer: as('alice') })

  const refused = write('/_/space/attributes', { path: '/notes/plan.md' })
  assertEquals((await worker.respond(refused, events())!).status, 409)
  assertEquals(sent[0]!.input, refused)
  assertEquals(cache.purged, [])

  status = 200
  const rows = write('/_/space/rows', { path: '/tasks.table', ops: [] })
  assertEquals((await worker.respond(rows, events())!).status, 200)
  assertEquals(sent[1]!.input, rows)
  assertEquals(cache.purged, ['alice query'])
  assertEquals(cache.puts, [])
  assertEquals(cache.kept('alice', 'query', key), undefined)
  assertEquals(cache.kept('alice', 'query', typedKey('["done"]')), undefined)
  assertEquals(cache.kept('alice', 'page', '/apps/tasks.html'), {
    body: '<p>tasks</p>',
    type: 'text/html',
    etag: null,
  })
})

Deno.test('a query in flight when a write commits keeps nothing', async () => {
  const cache = new MemoryCache()
  let answer!: (response: Response) => void
  const { fetch } = network((url) =>
    url.includes('/_/space/rows')
      ? viewed('{"rev":7,"ids":[3]}', { headers: jsonType, viewer: 'alice' })
      : new Promise<Response>((resolve) => answer = resolve)
  )
  const worker = pageWorker({ cache, fetch, origin, viewer: as('alice') })
  const crossing = events()
  const pending = worker.respond(request(typedPath('query', '[]')), crossing)!
  await tick()
  await worker.respond(write('/_/space/rows', {}), events())
  answer(viewed(typed('before'), { headers: jsonType, viewer: 'alice' }))
  assertEquals(await (await pending).text(), typed('before'))
  await crossing.settled()
  assertEquals(cache.puts, [])

  const after = events()
  const next = worker.respond(request(typedPath('query', '[]')), after)!
  await tick()
  answer(viewed(typed('after'), { headers: jsonType, viewer: 'alice' }))
  await (await next).text()
  await after.settled()
  assertEquals(cache.puts, [`alice query ${typedKey('[]')}`])
})

Deno.test('a page revalidated across a write still keeps its fresh HTML and says so', async () => {
  const cache = new MemoryCache()
  cache.seed('alice', 'page', '/apps/tasks.html', {
    body: '<p>one</p>',
    type: 'text/html',
    etag: '"1"',
  })
  let answer!: (response: Response) => void
  const { fetch } = network((url) =>
    url.includes('/_/space/rows')
      ? viewed('{"rev":7,"ids":[3]}', { headers: jsonType, viewer: 'alice' })
      : new Promise<Response>((resolve) => answer = resolve)
  )
  const worker = pageWorker({ cache, fetch, origin, viewer: as('alice') })
  const loading = events()
  const stale = await worker.respond(
    request('/apps/tasks.html', 'navigate'),
    loading,
  )!
  assertEquals(await stale.text(), '<p>one</p>')
  await worker.respond(write('/_/space/rows', {}), events())
  answer(viewed('<p>two</p>', {
    headers: { 'content-type': 'text/html', etag: '"2"' },
    viewer: 'alice',
  }))
  await loading.settled()
  assertEquals(loading.notes, [freshMessage])
  assertEquals(cache.kept('alice', 'page', '/apps/tasks.html'), {
    body: '<p>two</p>',
    type: 'text/html',
    etag: '"2"',
  })
})

Deno.test('an observed snapshot that crossed a write is relayed but not kept; the next one is', async () => {
  const cache = new MemoryCache()
  const live = controlled()
  const { fetch } = network((url) =>
    url.includes('/_/space/rows')
      ? viewed('{"rev":7,"ids":[]}', { headers: jsonType, viewer: 'alice' })
      : viewed(live.body, { headers: eventStream, viewer: 'alice' })
  )
  const worker = pageWorker({ cache, fetch, origin, viewer: as('alice') })
  const response = await worker.respond(
    request(typedPath('observe', '[]')),
    events(),
  )!
  const reader = response.body!.pipeThrough(new TextDecoderStream())
    .getReader()
  await worker.respond(write('/_/space/rows', {}), events())
  live.controller.enqueue(encoder.encode(`data: ${typed('crossed')}\n\n`))
  assertEquals((await reader.read()).value, `data: ${typed('crossed')}\n\n`)
  await tick()
  assertEquals(cache.puts, [])

  live.controller.enqueue(encoder.encode(`data: ${typed('next')}\n\n`))
  assertEquals((await reader.read()).value, `data: ${typed('next')}\n\n`)
  await tick()
  assertEquals(cache.kept('alice', 'query', typedKey('[]')), {
    body: typed('next'),
    type: 'application/json',
    etag: null,
  })
})

Deno.test('watch, attribute reads, methods other than POST and writes elsewhere are left to the network', () => {
  const cache = new MemoryCache()
  const { sent, fetch } = network(() => viewed('x', {}))
  const worker = pageWorker({ cache, fetch, origin, viewer: as('alice') })
  for (
    const path of [
      '/_/space/watch?glob=%2Fnotes%2F**&from=4',
      '/_/space/attributes?path=%2Fnotes%2Fplan.md',
    ]
  ) {
    assertEquals(worker.respond(request(path), events()), null)
  }
  for (
    const [path, method] of [
      ['/_/session', 'POST'],
      ['/_/space/rows', 'PUT'],
      ['/_/space/attributes', 'DELETE'],
    ]
  ) {
    assertEquals(
      worker.respond(new Request(origin + path, { method }), events()),
      null,
    )
  }
  assertEquals(sent.length, 0)
})

Deno.test('the viewer cookie prefers the __Host- name and falls back to the self-hosted one', async () => {
  const store = (cookies: Record<string, string>) => ({
    get: (name: string) =>
      Promise.resolve(
        name in cookies ? { name, value: cookies[name] } : null,
      ),
  })
  assertEquals(
    await cookieViewer(store({ '__Host-wuhu_viewer': 'flat' })),
    'flat',
  )
  assertEquals(await cookieViewer(store({ wuhu_viewer: 'legacy' })), 'legacy')
  assertEquals(
    await cookieViewer(
      store({ '__Host-wuhu_viewer': 'flat', wuhu_viewer: 'legacy' }),
    ),
    'flat',
  )
  assertEquals(await cookieViewer(store({})), '')
})
