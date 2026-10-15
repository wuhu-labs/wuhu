import { assertEquals, assertRejects } from 'jsr:@std/assert@1'
import { generateKey } from './assertion.ts'
import {
  currentAssertion,
  forgetServerClock,
  recoverFromClockRefusal,
  signedAssertion,
} from './auth.ts'
import { SpaceServer } from './client.ts'
import { ApiError } from './errors.ts'
import { api, onUnauthorized } from './http.ts'
import { openAuthorizedStream } from './sse.ts'

// One enrolled browser against a server that checks nbf and exp by its own
// clock with no leeway, as AssertionGate does.
function request<T>(result: T) {
  const pending: { result: T; onsuccess?: () => void } = { result }
  queueMicrotask(() => pending.onsuccess?.())
  return pending
}
const device = { ...(await generateKey('ed25519')), spaceId: 'sha256:space' }
globalThis.indexedDB = {
  open: () =>
    request({
      transaction: () => ({
        objectStore: () => ({ get: () => request(device) }),
      }),
      close() {},
    }),
} as unknown as IDBFactory

let serverMs = 1_750_000_000_000
let browserAheadMs = -90_000
Date.now = () => serverMs + browserAheadMs
let revoked = false
let badSignature = false
// Every request in order; `clock` is the unsigned reading of /v1/server.
let sent: string[] = []
let refusals: string[] = []
let signOuts = 0
onUnauthorized(() => signOuts++)

const readClock = () =>
  Promise.resolve(
    Response.json({ now: serverMs / 1000, contentBase: 'space.test' }),
  )
let clockReply: (init?: RequestInit) => Promise<Response> = readClock
// A request to this url is answered only once `release` is called.
let held: { url: string; released: Promise<void> } | null = null

function claims(authorization: string): { nbf?: number; exp: number } {
  const segment = authorization.split('.')[1]!.replaceAll('-', '+')
    .replaceAll('_', '/')
  return JSON.parse(atob(segment))
}

function refusal(message: string, reason?: string): Response {
  refusals.push(reason ?? 'unauthorized')
  return Response.json({
    code: 'unauthorized',
    message,
    ...(reason == null ? {} : { reason }),
  }, { status: 401 })
}

function gate(authorization: string | null): Response | null {
  if (revoked) return refusal('your device key was revoked')
  if (badSignature) return refusal('assertion signature rejected')
  const { nbf, exp } = claims(authorization!)
  const now = serverMs / 1000
  if (now >= exp) return refusal('assertion expired', 'assertionExpired')
  if (nbf !== undefined && now < nbf) {
    return refusal('assertion not yet valid', 'assertionNotYetValid')
  }
  return null
}

globalThis.fetch = (input: RequestInfo | URL, init?: RequestInit) => {
  const url = String(input)
  const authorization = new Headers(init?.headers).get('authorization')
  if (url === '/v1/server' && authorization == null) {
    sent.push('clock')
    return clockReply(init)
  }
  sent.push(url)
  if (held?.url === url) {
    const { released } = held
    held = null
    return released.then(() => answer(url, authorization, init))
  }
  return answer(url, authorization, init)
}

function answer(
  url: string,
  authorization: string | null,
  init?: RequestInit,
): Promise<Response> {
  const refused = gate(authorization)
  if (refused != null) return Promise.resolve(refused)
  if (url === '/v1/server') return readClock()
  if (url === '/v1/transcribe') {
    return Promise.resolve(Response.json(
      { code: 'provider_auth', message: 'provider login expired' },
      { status: 502 },
    ))
  }
  if (url === '/v1/observe') {
    return Promise.resolve(
      new Response(
        new ReadableStream({
          start(stream) {
            init?.signal?.addEventListener('abort', () => stream.close(), {
              once: true,
            })
          },
        }),
        {
          headers: { 'content-type': 'text/event-stream' },
        },
      ),
    )
  }
  return Promise.resolve(Response.json({ ok: true }))
}

const count = (entry: string) => sent.filter((it) => it === entry).length

// A browser that has not read the server's clock yet.
function cold(aheadMs: number): void {
  serverMs = 1_750_000_000_000
  browserAheadMs = aheadMs
  revoked = false
  badSignature = false
  clockReply = readClock
  held = null
  forgetServerClock()
  sent = []
  refusals = []
  signOuts = 0
}

// One that has.
async function start(aheadMs: number): Promise<void> {
  cold(aheadMs)
  await currentAssertion()
  sent = []
}

function hold(url: string): () => void {
  let release!: () => void
  held = { url, released: new Promise((resolve) => release = resolve) }
  return release
}

async function untilSent(url: string): Promise<void> {
  while (!sent.includes(url)) await new Promise((it) => setTimeout(it, 1))
}

function stream(): Promise<'open' | number | undefined> {
  return new Promise((resolve) => {
    const opened = openAuthorizedStream('/v1/observe')
    opened.onOpen(() => {
      opened.close()
      resolve('open')
    })
    opened.onError(resolve)
  })
}

Deno.test('a cold first signed call reads the clock before it signs', async () => {
  cold(-90_000)
  assertEquals(await api('/v1/tools/ls'), { ok: true })
  assertEquals(sent, ['clock', '/v1/tools/ls'])
  assertEquals(refusals, [])
  assertEquals(signOuts, 0)
})

// The old client signed exp by the browser's clock and reused it until 60 s
// before: 90 s slow, the server saw it expire 30 s early in every window.
for (const [clock, aheadMs] of [['behind', -90_000], ['ahead', 90_000]]) {
  Deno.test(`a browser clock 90 s ${clock} never meets a 401 nor signs out`, async () => {
    await start(aheadMs as number)
    for (let elapsed = 0; elapsed <= 900; elapsed += 15) {
      assertEquals(await api('/v1/tools/ls'), { ok: true }, `at +${elapsed}s`)
      assertEquals(await stream(), 'open', `stream at +${elapsed}s`)
      serverMs += 15_000
    }
    assertEquals(refusals, [])
    assertEquals(count('clock'), 0)
    assertEquals(signOuts, 0)
  })
}

for (
  const [clock, jumpMs, refused] of [
    ['back', -90_000, 'assertionExpired'],
    ['forward', 90_000, 'assertionNotYetValid'],
  ]
) {
  Deno.test(`a browser clock jumping ${clock} after the sync is re-signed once, never a sign-out`, async () => {
    await start(0)
    assertEquals(await api('/v1/tools/ls'), { ok: true })
    browserAheadMs = jumpMs as number
    for (let elapsed = 0; elapsed <= 600; elapsed += 15) {
      serverMs += 15_000
      assertEquals(await api('/v1/tools/ls'), { ok: true }, `at +${elapsed}s`)
    }
    assertEquals(refusals, [refused])
    assertEquals(count('clock'), 1)
    assertEquals(count('/v1/tools/ls'), 43)
    assertEquals(signOuts, 0)
  })

  Deno.test(`a stream whose browser clock jumped ${clock} is re-signed once and opens`, async () => {
    await start(0)
    assertEquals(await stream(), 'open')
    browserAheadMs = jumpMs as number
    serverMs += 305_000
    assertEquals(await stream(), 'open')
    assertEquals(refusals, [refused])
    assertEquals(sent, ['/v1/observe', '/v1/observe', 'clock', '/v1/observe'])
    assertEquals(signOuts, 0)
  })
}

Deno.test('a burst of clock refusals reads the clock once', async () => {
  await start(0)
  const stale = (await signedAssertion())!.clock
  browserAheadMs = -90_000
  serverMs += 305_000
  const answers = await Promise.all(
    Array.from({ length: 5 }, () => api('/v1/tools/ls')),
  )
  assertEquals(answers, Array(5).fill({ ok: true }))
  assertEquals(refusals, Array(5).fill('assertionExpired'))
  assertEquals(count('clock'), 1)
  assertEquals(count('/v1/tools/ls'), 10)
  // A refusal arriving late, signed by the reading since replaced, reads
  // nothing.
  await recoverFromClockRefusal(stale)
  assertEquals(count('clock'), 1)
  assertEquals(signOuts, 0)
})

// The server clock jumps 500 s ahead while assertion A, 70 s from its expiry
// by the old reading, is in flight. Before A's refusal lands, an ordinary
// renewal signs B by the same old reading, so B is expired on arrival too.
Deno.test('a refusal reads the clock even after a renewal signed by the same reading', async () => {
  await start(0)
  const a = (await signedAssertion())!
  serverMs += 730_000
  browserAheadMs = -500_000
  const release = hold('/v1/tools/held')
  const answer = api('/v1/tools/held')
  await untilSent('/v1/tools/held')
  serverMs += 20_000
  const b = (await signedAssertion())!
  assertEquals([b.assertion !== a.assertion, b.clock], [true, a.clock])
  release()
  assertEquals(await answer, { ok: true })
  assertEquals(refusals, ['assertionExpired'])
  assertEquals(sent, ['/v1/tools/held', 'clock', '/v1/tools/held'])
  assertEquals(signOuts, 0)
})

Deno.test('a content cookie mint refused for its times is re-signed once', async () => {
  await start(0)
  const server = new SpaceServer()
  await server.info()
  browserAheadMs = -90_000
  serverMs += 305_000
  const origin = await server.client('shared').contentOrigin()
  assertEquals(origin, 'https://shared.space.test')
  assertEquals(refusals, ['assertionExpired'])
  assertEquals(sent, [
    '/v1/server',
    'https://shared.space.test/_/session',
    'clock',
    'https://shared.space.test/_/session',
  ])
  assertEquals(signOuts, 0)
})

Deno.test('a stuck or failed clock reading is let go, and a later refusal reads again without a reload', async () => {
  await start(0)
  assertEquals(await api('/v1/tools/ls'), { ok: true })
  // Ahead far enough that the next call renews, with an nbf the server has
  // not reached.
  browserAheadMs = 90_000
  serverMs += 160_000
  clockReply = (init) =>
    new Promise((_, reject) =>
      init?.signal?.addEventListener('abort', () => reject(init.signal!.reason))
    )
  const realSetTimeout = globalThis.setTimeout
  const timers: (() => void)[] = []
  globalThis.setTimeout = ((handler: () => void) => {
    timers.push(handler)
    return 0
  }) as unknown as typeof setTimeout
  try {
    const stuck = assertRejects(() => api('/v1/tools/ls'), ApiError)
    while (timers.length === 0) {
      await new Promise((resolve) => realSetTimeout(resolve, 1))
    }
    timers.shift()!()
    const failure = await stuck
    assertEquals([failure.status, failure.detail.reason], [
      401,
      'assertionNotYetValid',
    ])
  } finally {
    globalThis.setTimeout = realSetTimeout
  }

  clockReply = () => Promise.reject(new TypeError('offline'))
  await assertRejects(() => api('/v1/tools/ls'), ApiError)

  clockReply = readClock
  assertEquals(await api('/v1/tools/ls'), { ok: true })
  assertEquals(sent, [
    '/v1/tools/ls',
    '/v1/tools/ls',
    'clock',
    '/v1/tools/ls',
    '/v1/tools/ls',
    'clock',
    '/v1/tools/ls',
    '/v1/tools/ls',
    'clock',
    '/v1/tools/ls',
  ])
  assertEquals(signOuts, 0)
})

Deno.test('a revoked key still signs out, on requests and streams alike', async () => {
  await start(-90_000)
  revoked = true
  const failure = await assertRejects(() => api('/v1/tools/ls'), ApiError)
  assertEquals([failure.status, failure.code], [401, 'unauthorized'])
  assertEquals(await stream(), 401)
  assertEquals(refusals, ['unauthorized', 'unauthorized'])
  assertEquals(count('clock'), 0)
  assertEquals(signOuts, 2)
})

Deno.test('a plain unauthorized with no reason signs out without a retry', async () => {
  await start(0)
  badSignature = true
  await assertRejects(() => api('/v1/tools/ls'), ApiError)
  assertEquals(sent, ['/v1/tools/ls'])
  assertEquals(signOuts, 1)
})

Deno.test('a provider auth failure is an error, not a sign-out', async () => {
  await start(0)
  const failure = await assertRejects(() => api('/v1/transcribe'), ApiError)
  assertEquals([failure.status, failure.code], [502, 'provider_auth'])
  assertEquals(signOuts, 0)
})
