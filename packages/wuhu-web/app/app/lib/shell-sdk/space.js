// @ts-self-types="./space.d.ts"

// `wuhu:space` for pages: the shared core over the `/_/space/*` routes of the
// page's own origin, as the viewer's read cookie.
import { sseParser } from './open-cache.js'
import { createSpace, failure, SpaceError } from './space-core.js'

// Like EventSource, a live stream whose connection drops or ends opens again
// after this long; only an error status ends it.
const reconnectDelay = 3000

// Percent-encoded throughout: the server reads a `+` as itself, not a space.
function address(route, parameters = {}) {
  const search = Object.entries(parameters)
    .filter(([, value]) => value !== null)
    .map(([name, value]) => `${name}=${encodeURIComponent(value)}`)
    .join('&')
  return `${location.origin}/_/space/${route}${
    search === '' ? '' : `?${search}`
  }`
}

const boundParameters = (params) =>
  params.length === 0 ? null : JSON.stringify(params)

// A refusal the server explains carries its code; any other non-2xx answer,
// a proxy's 502 or a plain-text 404, is `internal`.
const refusal = async (response) =>
  failure(await response.json().catch(() => null), `HTTP ${response.status}`)

async function answer(response) {
  if (!response.ok) throw await refusal(response)
  return await response.json()
}

function send(route, body) {
  return globalThis.fetch(address(route), {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ ...body, page: location.pathname }),
  }).then(answer)
}

function pause(signal) {
  return new Promise((resolve) => {
    const aborted = () => {
      clearTimeout(timer)
      resolve()
    }
    const timer = setTimeout(() => {
      signal.removeEventListener('abort', aborted)
      resolve()
    }, reconnectDelay)
    signal.addEventListener('abort', aborted, { once: true })
  })
}

// Each message until the connection drops or ends.
async function* messages(body) {
  const reader = body.pipeThrough(new TextDecoderStream()).getReader()
  const parser = sseParser()
  for (;;) {
    let chunk
    try {
      chunk = await reader.read()
    } catch {
      return
    }
    if (chunk.done) return
    yield* parser.push(chunk.value)
  }
}

async function* connections(target, signal) {
  while (!signal.aborted) {
    const response = await globalThis.fetch(target(), { signal }).catch(() =>
      null
    )
    if (response !== null && !response.ok) throw await refusal(response)
    if (response !== null) {
      for await (const { event, data } of messages(response.body)) {
        yield { event, data: JSON.parse(data) }
      }
    }
    if (!signal.aborted) await pause(signal)
  }
}

// `target` names the URL of each connection, so a stream can resume where
// the last one stopped. The stream yields `message` values; `frames` hears
// the other named events.
function stream(target, frames = {}) {
  const abort = new AbortController()
  const records = connections(target, abort.signal)
  return {
    async next() {
      for (;;) {
        const { done, value: record } = await records.next()
        if (done) return null
        if (record.event === 'message') return record.data
        frames[record.event]?.(record.data)
      }
    },
    close: () => abort.abort(),
  }
}

const httpTransport = {
  query: (sql, params) =>
    globalThis.fetch(address('query', { sql, params: boundParameters(params) }))
      .then(
        answer,
      ),
  observe: (sql, params) =>
    stream(() => address('observe', { sql, params: boundParameters(params) })),
  // Without `from`, the server opens with a `head` frame naming the revision
  // the stream starts after, so a drop before the first event resumes there.
  watch(glob, from) {
    let after = from
    let boundary = null
    const delivered = new Set()
    const abort = new AbortController()
    const records = connections(() =>
      address('watch', {
        glob,
        from: boundary === null ? after : boundary - 1,
        batch: 1,
      }), abort.signal)
    const keyOf = (event) =>
      JSON.stringify([event.kind, event.path, event.to ?? null])
    const admit = (event) => {
      if (boundary !== null && event.rev < boundary) return false
      if (event.rev !== boundary) {
        boundary = event.rev
        delivered.clear()
      }
      const key = keyOf(event)
      if (delivered.has(key)) return false
      delivered.add(key)
      return true
    }
    const events = (async function* () {
      for await (const frame of records) {
        if (frame.event === 'head') {
          after ??= frame.data.rev
        } else if (frame.event === 'revision') {
          const revision = frame.data
          if (
            !Number.isSafeInteger(revision.rev) || revision.rev < 0 ||
            !Array.isArray(revision.events) ||
            !revision.events.every((event) => event.rev === revision.rev)
          ) {
            throw new SpaceError('internal', 'Invalid watch revision')
          }
          if (boundary !== null && revision.rev < boundary) continue
          const replayed = boundary === revision.rev ? delivered : new Set()
          for (const event of revision.events) {
            if (!replayed.has(keyOf(event))) yield event
          }
          after = revision.rev
          boundary = null
          delivered.clear()
        } else if (frame.event === 'message' && admit(frame.data)) {
          yield frame.data
        }
      }
    })()
    return {
      async next() {
        const { value, done } = await events.next()
        return done ? null : value
      },
      close: () => abort.abort(),
    }
  },
  mutateRows: (path, ops) => send('rows', { path, ops }),
  readAttributes: (path) =>
    globalThis.fetch(address('attributes', { path })).then(answer),
  patchAttributes: (path, { set, remove, ifMatch }) =>
    send('attributes', { path, set, remove, ifMatch }),
  find: (search) => globalThis.fetch(address('find', search)).then(answer),
  grep: (search) => globalThis.fetch(address('grep', search)).then(answer),
}

export const {
  query,
  observe,
  watch,
  mutateRows,
  readAttributes,
  patchAttributes,
  find,
  grep,
} = createSpace(httpTransport)
export { SpaceError }

// The viewer's own agents, kept to this page's group: wuhu:session's
// createSession and sendMessage, minus what only a session has.
export async function createSession(options) {
  const made = await send('session', options)
  const result = { id: made.id }
  for (
    const key of [
      'requestId',
      'existing',
      'modelGroup',
      'member',
      'provider',
      'model',
    ]
  ) {
    if (made[key] != null) result[key] = made[key]
  }
  return result
}

export async function sendMessage(options) {
  const { messageId, conversationId } = await send('message', options)
  return { messageId, conversationId }
}

export async function fetch(input, init = {}) {
  const target = new Request(input, init)
  const headers = Object.fromEntries(target.headers)
  if (target.headers.has('authorization')) {
    throw new SpaceError(
      'fetchAuthorizationForbidden',
      'a page cannot set Authorization on proxied fetch',
    )
  }
  const response = await globalThis.fetch(
    address('fetch', {
      url: target.url,
      method: target.method,
      headers: JSON.stringify(headers),
      page: location.pathname,
    }),
    {
      method: 'POST',
      credentials: 'same-origin',
      body: await fetchRequestBody(target),
      signal: target.signal,
    },
  )
  if (response.headers.get('wuhu-fetch-result') !== 'upstream') {
    throw await refusal(response)
  }
  return response
}

async function fetchRequestBody(target) {
  target.signal.throwIfAborted()
  if (target.body === null) return undefined
  const reader = target.body.getReader()
  const abort = () => {
    void reader.cancel(target.signal.reason).catch(() => {})
  }
  target.signal.addEventListener('abort', abort, { once: true })
  const chunks = []
  let length = 0
  try {
    for (;;) {
      target.signal.throwIfAborted()
      const { value, done } = await reader.read()
      target.signal.throwIfAborted()
      if (done) break
      chunks.push(value)
      length += value.byteLength
    }
    const bytes = new Uint8Array(length)
    let offset = 0
    for (const chunk of chunks) {
      bytes.set(chunk, offset)
      offset += chunk.byteLength
    }
    return bytes.buffer
  } finally {
    target.signal.removeEventListener('abort', abort)
    reader.releaseLock()
  }
}
