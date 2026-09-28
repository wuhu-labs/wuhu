import {
  byteLength,
  normalizeSQL,
  openCache,
  pageCacheBudgets,
  sharedGroup,
  sseParser,
} from './open-cache.js'

const json = 'application/json'
const encoder = new TextEncoder()

// Messages to the page's shell: fresh HTML replaced what it painted, or the
// space refused its read cookie.
export const freshMessage = { type: 'wuhu:fresh' }
export const unauthorizedMessage = { type: 'wuhu:unauthorized' }

function sseEvent(data) {
  return encoder.encode(
    `${data.split('\n').map((line) => `data: ${line}`).join('\n')}\n\n`,
  )
}

// A kept page replays its Content-Security-Policy: a group host's
// frame-ancestors must hold for a cached copy as for the network one, or a
// sibling host could frame it through this worker.
function stored(entry) {
  const headers = { 'content-type': entry.type }
  if (entry.csp != null) headers['content-security-policy'] = entry.csp
  return new Response(entry.body, { headers })
}

// A typed statement is kept apart from its legacy form, under its bound
// parameters as the page sent them.
function spaceKey(url) {
  const sql = normalizeSQL(url.searchParams.get('sql'))
  return `space\n${sql}\n${url.searchParams.get('params') ?? ''}`
}

// Product chrome (shell.js, view providers) is never stored here; offline it
// is whatever the browser's HTTP cache still holds, so a new server build is
// picked up on the next load.
function fromNetwork(request, fetch) {
  return fetch(request).catch(() =>
    fetch(
      new Request(request.url, {
        mode: 'same-origin',
        cache: 'only-if-cached',
      }),
    )
  )
}

// A cache that fails is an empty one; the network still answers.
function forgiving(cache) {
  return {
    get: (scope, kind, key) =>
      cache.get(scope, kind, key).catch(() => undefined),
    put: (scope, kind, key, value, bytes) =>
      cache.put(scope, kind, key, value, bytes).catch(() => undefined),
    purge: (scope, kind) => cache.purge(scope, kind).catch(() => undefined),
  }
}

// Page HTML, /_/query and /_/space/query are stale-while-revalidate;
// /_/observe?sql= and /_/space/observe answer with the cached snapshot as their
// first event, then the live stream. /_/space/watch and page writes go
// straight to the network, and nothing of a write is kept.
//
// Entries are written under the viewer the server names in Wuhu-Viewer and
// read under the one the browser's wuhu_viewer cookie names, which the mint
// sets with the read cookie, so one account's results never answer another.
// The first request after that cookie changes, sign-out included, purges what
// the previous viewer kept.
//
// A committed write drops the query results its viewer kept, before the page
// sees its answer. `epoch` counts those writes: a result fetched across one is
// relayed but not kept.
export function pageWorker({ cache: backing, fetch, origin, viewer }) {
  const cache = forgiving(backing)
  let epoch = 0
  const viewerRecord = { space: origin, group: '', viewer: '' }
  const scopeOf = (account) => ({
    space: origin,
    group: sharedGroup,
    viewer: account,
  })
  let known = null
  const readScope = async () => {
    const current = await viewer()
    known ??= cache.get(viewerRecord, 'meta', 'viewer').then((kept) =>
      kept ?? ''
    )
    const previous = await known
    if (previous !== current) {
      known = Promise.resolve(current)
      await cache.purge(scopeOf(previous))
      await cache.put(
        viewerRecord,
        'meta',
        'viewer',
        current,
        byteLength(current),
      )
    }
    return scopeOf(current)
  }
  const writeScope = (response) =>
    scopeOf(response.headers.get('wuhu-viewer') ?? '')

  const answered = (response, notify) => {
    if (response.status === 401) notify(unauthorizedMessage)
    return response
  }

  // Stored from a clone, so the page streams while the copy is written.
  const keep = async (response, kind, key, since) => {
    const type = response.headers.get('content-type') ?? ''
    if (!response.ok || !(kind === 'query' || type.startsWith('text/html'))) {
      return null
    }
    const body = await response.clone().text()
    if (kind === 'query' && since !== epoch) return null
    const entry = { body, type, etag: response.headers.get('etag') }
    const csp = response.headers.get('content-security-policy')
    if (csp !== null) entry.csp = csp
    await cache.put(writeScope(response), kind, key, entry, byteLength(body))
    return body
  }

  const revalidating = async (request, kind, key, { waitUntil, notify }) => {
    const since = epoch
    const cached = await cache.get(await readScope(), kind, key)
    const live = fetch(request.url, {
      headers: cached?.etag == null ? {} : { 'if-none-match': cached.etag },
    }).then((response) => answered(response, notify))
    if (cached === undefined) {
      const response = await live
      waitUntil(keep(response, kind, key, since))
      return response
    }
    waitUntil(
      live.then(async (response) => {
        const body = await keep(response, kind, key, since)
        if (kind === 'page' && body !== null && body !== cached.body) {
          notify(freshMessage)
        }
      }).catch(() => undefined),
    )
    return stored(cached)
  }

  // A snapshot that crossed a write is relayed but not kept; the next one is.
  const recorded = (response, key, opened) => {
    let since = opened
    const save = (data) => {
      if (since === epoch) {
        void cache.put(
          writeScope(response),
          'query',
          key,
          { body: data, type: json, etag: null },
          byteLength(data),
        )
      }
      since = epoch
    }
    const decoder = new TextDecoder()
    const parser = sseParser()
    return response.body.pipeThrough(
      new TransformStream({
        transform(chunk, controller) {
          controller.enqueue(chunk)
          for (
            const { data } of parser.push(
              decoder.decode(chunk, { stream: true }),
            )
          ) {
            save(data)
          }
        },
      }),
    )
  }

  // Keys whose live answer was refused: the page's reconnect goes straight to
  // the network, so the refusal reaches its EventSource as it would without
  // this worker, instead of the kept snapshot painting again.
  const refused = new Set()

  // A live stream that fails or ends closes this one too, and the page's
  // EventSource reconnects through here again.
  const cachedThenLive = (snapshot, request, key, notify) => {
    const upstream = new AbortController()
    return new ReadableStream({
      start(controller) {
        controller.enqueue(sseEvent(snapshot))
        const pump = async () => {
          const since = epoch
          const response = answered(
            await fetch(request, { signal: upstream.signal }),
            notify,
          )
          if (!response.ok || response.body == null) {
            refused.add(key)
            return
          }
          const reader = recorded(response, key, since).getReader()
          for (;;) {
            const { done, value } = await reader.read()
            if (done) return
            controller.enqueue(value)
          }
        }
        pump().catch(() => undefined).finally(() => {
          if (!upstream.signal.aborted) controller.close()
        })
      },
      cancel() {
        upstream.abort()
      },
    })
  }

  const observing = async (request, key, { notify }) => {
    const since = epoch
    const cached = await cache.get(await readScope(), 'query', key)
    if (cached === undefined || refused.delete(key)) {
      const response = answered(await fetch(request), notify)
      if (!response.ok || response.body == null) return response
      return new Response(recorded(response, key, since), response)
    }
    return new Response(cachedThenLive(cached.body, request, key, notify), {
      headers: {
        'content-type': 'text/event-stream',
        'cache-control': 'no-cache',
      },
    })
  }

  const written = async (request, { notify }) => {
    const response = answered(await fetch(request), notify)
    if (response.ok) {
      epoch += 1
      await cache.purge(writeScope(response), 'query')
    }
    return response
  }

  return {
    respond(request, events) {
      const url = new URL(request.url)
      if (url.origin !== origin) return null
      const space = url.pathname.startsWith('/_/space/')
      if (request.method !== 'GET') {
        return space && request.method === 'POST'
          ? written(request, events)
          : null
      }
      const sql = url.searchParams.get('sql')
      if (url.pathname === '/_/query' && sql !== null) {
        return revalidating(request, 'query', normalizeSQL(sql), events)
      }
      if (url.pathname === '/_/observe' && sql !== null) {
        return observing(request, normalizeSQL(sql), events)
      }
      if (url.pathname === '/_/space/query' && sql !== null) {
        return revalidating(request, 'query', spaceKey(url), events)
      }
      if (url.pathname === '/_/space/observe' && sql !== null) {
        return observing(request, spaceKey(url), events)
      }
      if (space) return null
      if (request.mode === 'navigate' && !url.pathname.startsWith('/_/')) {
        return revalidating(request, 'page', url.pathname + url.search, events)
      }
      return fromNetwork(request, fetch)
    },
  }
}

if (
  typeof ServiceWorkerGlobalScope !== 'undefined' &&
  self instanceof ServiceWorkerGlobalScope
) {
  const worker = pageWorker({
    cache: openCache({ budgets: pageCacheBudgets }),
    fetch: (input, init) => fetch(input, init),
    origin: self.location.origin,
    viewer: () =>
      self.cookieStore.get('wuhu_viewer').then((cookie) => cookie?.value ?? ''),
  })
  self.addEventListener('install', () => self.skipWaiting())
  self.addEventListener(
    'activate',
    (event) => event.waitUntil(self.clients.claim()),
  )
  self.addEventListener('fetch', (event) => {
    const response = worker.respond(event.request, {
      waitUntil: (promise) => event.waitUntil(promise),
      notify: (message) =>
        void self.clients.get(event.resultingClientId || event.clientId)
          .then((client) => client?.postMessage(message)),
    })
    if (response !== null) event.respondWith(response)
  })
}
