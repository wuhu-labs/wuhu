import {
  bounded,
  type EventStream,
  type Network,
  observeStore,
  type Subscription,
  type Timer,
} from './observe.ts'
import type { ViewerCache } from './open-cache.ts'
import {
  conversationBytes,
  conversationSubscription,
  directSubscription,
  transcriptBytes,
} from './subscriptions.ts'
import type {
  ConversationMessagePayload,
  SessionStreamEvent,
} from '~/lib/contract.gen'
import { byteLength } from '~/lib/shell-sdk/open-cache.js'

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message)
}

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

class FakeStream implements EventStream {
  closed = false
  private openHandler: (() => void) | null = null
  private messageHandler: ((data: string) => void) | null = null
  private activityHandler: (() => void) | null = null
  private errorHandler: (() => void) | null = null

  constructor(readonly url: string) {}

  onOpen(handler: () => void) {
    this.openHandler = handler
  }
  onMessage(handler: (data: string) => void) {
    this.messageHandler = handler
  }
  onActivity(handler: () => void) {
    this.activityHandler = handler
  }
  onError(handler: () => void) {
    this.errorHandler = handler
  }
  close() {
    this.closed = true
  }

  fireOpen() {
    this.openHandler?.()
  }
  send(value: unknown) {
    this.messageHandler?.(JSON.stringify(value))
  }
  heartbeat() {
    this.activityHandler?.()
  }
  fail() {
    this.errorHandler?.()
  }
}

class FakeNet {
  readonly streams: FakeStream[] = []
  open = (url: string): EventStream => {
    const stream = new FakeStream(url)
    this.streams.push(stream)
    return stream
  }
  get last(): FakeStream {
    return this.streams[this.streams.length - 1]!
  }
  get urls(): string[] {
    return this.streams.map((stream) => stream.url)
  }
}

class FakeTimer implements Timer {
  readonly delays: number[] = []
  private pending: { run: () => void }[] = []
  schedule = (delayMs: number, run: () => void) => {
    const entry = { run }
    this.pending.push(entry)
    this.delays.push(delayMs)
    return () => {
      const index = this.pending.indexOf(entry)
      if (index >= 0) this.pending.splice(index, 1)
    }
  }
  fire() {
    const entry = this.pending.shift()
    if (!entry) throw new Error('no timer pending')
    entry.run()
  }
  get pendingCount(): number {
    return this.pending.length
  }
}

// Every connect also schedules its 10s open deadline, and every open its 45s
// stale deadline; backoffs() reads the reconnect delays alone.
function backoffs(timer: FakeTimer): number[] {
  return timer.delays.filter((delay) => delay < 10_000)
}

interface RevEvent {
  rev: number
  path: string
}

function revSubscription(from: number): Subscription<RevEvent> {
  return {
    from,
    url: (cursor) => `/observe?from=${cursor ?? from}`,
    cursorOf: (event) => event.rev,
  }
}

function collectStore<Event>(
  net: FakeNet,
  timer: FakeTimer,
  subscription: Subscription<Event>,
) {
  const changes: number[] = []
  const store = observeStore<Event[], Event>({
    subscription,
    fold: (data, event) => [...data, event],
    initial: [],
    open: net.open,
    timer,
  })
  const unsubscribe = store.subscribe(() => changes.push(1))
  return { store, unsubscribe, changes }
}

Deno.test('opens the initial cursor and goes live on open', () => {
  const net = new FakeNet()
  const timer = new FakeTimer()
  const { store } = collectStore(net, timer, revSubscription(7))

  assertEquals(net.urls, ['/observe?from=7'])
  assertEquals(store.getSnapshot().liveness, 'reconnecting')
  net.last.fireOpen()
  assertEquals(store.getSnapshot().liveness, 'live')
})

Deno.test('folds events and keeps same-rev siblings', () => {
  const net = new FakeNet()
  const timer = new FakeTimer()
  const { store } = collectStore(net, timer, revSubscription(0))
  net.last.fireOpen()
  net.last.send({ rev: 5, path: '/a' })
  net.last.send({ rev: 5, path: '/b' })
  net.last.send({ rev: 6, path: '/c' })

  assertEquals(store.getSnapshot().data, [
    { rev: 5, path: '/a' },
    { rev: 5, path: '/b' },
    { rev: 6, path: '/c' },
  ])
})

Deno.test('reconnect resumes from the last applied rev and drops replays', () => {
  const net = new FakeNet()
  const timer = new FakeTimer()
  const { store } = collectStore(net, timer, revSubscription(0))
  net.last.fireOpen()
  net.last.send({ rev: 1, path: '/a' })
  net.last.send({ rev: 2, path: '/b' })

  net.last.fail()
  assert(net.streams[0]!.closed, 'failed stream must be closed by the seam')
  assertEquals(store.getSnapshot().liveness, 'reconnecting')
  // Stale data is kept across the disconnect.
  assertEquals(store.getSnapshot().data.length, 2)

  timer.fire()
  assertEquals(net.last.url, '/observe?from=2')
  net.last.fireOpen()
  assertEquals(store.getSnapshot().liveness, 'live')
  // A replayed older rev is dropped; a fresh rev is applied.
  net.last.send({ rev: 1, path: '/a' })
  net.last.send({ rev: 3, path: '/c' })
  assertEquals(store.getSnapshot().data, [
    { rev: 1, path: '/a' },
    { rev: 2, path: '/b' },
    { rev: 3, path: '/c' },
  ])
})

Deno.test('backoff escalates and resets on a successful open', () => {
  const net = new FakeNet()
  const timer = new FakeTimer()
  const { store } = collectStore(net, timer, revSubscription(0))
  net.last.fireOpen()
  net.last.fail()
  timer.fire()
  net.last.fail()
  timer.fire()
  net.last.fail()
  assertEquals(backoffs(timer), [250, 500, 1000])

  timer.fire()
  net.last.fireOpen()
  net.last.fail()
  // A live open resets the backoff to the first step.
  assertEquals(backoffs(timer), [250, 500, 1000, 250])
  assertEquals(store.getSnapshot().liveness, 'reconnecting')
})

Deno.test('a connection attempt that never opens times out and retries', () => {
  const net = new FakeNet()
  const timer = new FakeTimer()
  const { store } = collectStore(net, timer, revSubscription(4))
  // Nothing arrives: no open, no error — a fetch left pending forever.
  assertEquals(timer.delays, [10_000])
  timer.fire()
  assert(net.streams[0]!.closed, 'the wedged attempt must be closed')
  assertEquals(store.getSnapshot().liveness, 'reconnecting')

  timer.fire()
  assertEquals(net.last.url, '/observe?from=4')
  net.last.fireOpen()
  assertEquals(store.getSnapshot().liveness, 'live')
  // The open deadline is gone; only the stale deadline still pends.
  assertEquals(timer.pendingCount, 1)
})

Deno.test('a silent open stream goes stale and reconnects', () => {
  const net = new FakeNet()
  const timer = new FakeTimer()
  const { store } = collectStore(net, timer, revSubscription(0))
  net.last.fireOpen()
  assertEquals(store.getSnapshot().liveness, 'live')
  // Only the stale deadline is pending; firing it declares the stream dead.
  assertEquals(timer.pendingCount, 1)
  timer.fire()
  assert(net.streams[0]!.closed, 'the stale stream must be closed')
  assertEquals(store.getSnapshot().liveness, 'reconnecting')

  timer.fire()
  net.last.fireOpen()
  assertEquals(store.getSnapshot().liveness, 'live')
})

Deno.test('heartbeat activity keeps a quiet stream alive', () => {
  const net = new FakeNet()
  const timer = new FakeTimer()
  const { store } = collectStore(net, timer, revSubscription(0))
  net.last.fireOpen()
  net.last.heartbeat()
  net.last.heartbeat()
  // Each heartbeat replaced the stale deadline instead of stacking new ones.
  assertEquals(timer.delays.filter((d) => d === 45_000).length, 3)
  assertEquals(timer.pendingCount, 1)
  assertEquals(store.getSnapshot().liveness, 'live')
  assertEquals(net.streams.length, 1)
})

Deno.test('an error from a superseded stream is ignored', () => {
  const net = new FakeNet()
  const timer = new FakeTimer()
  collectStore(net, timer, revSubscription(0))
  const wedged = net.last
  timer.fire()
  timer.fire()
  const replacement = net.last
  assert(wedged !== replacement, 'the deadline must open a fresh attempt')
  replacement.fireOpen()

  wedged.fail()
  // The superseded failure schedules nothing; the one pending timer is the
  // live stream's stale deadline.
  assertEquals(timer.pendingCount, 1)
})

Deno.test('cursorless SQL subscription replaces wholesale and keeps stale on reconnect', () => {
  const net = new FakeNet()
  const timer = new FakeTimer()
  const url = '/observe?sql=SELECT'
  const subscription: Subscription<{ rows: number[] }> = {
    from: null,
    url: () => url,
    cursorOf: () => null,
  }
  const store = observeStore<number[], { rows: number[] }>({
    subscription,
    fold: (_, snapshot) => snapshot.rows,
    initial: [],
    open: net.open,
    timer,
  })
  store.subscribe(() => {})

  net.last.fireOpen()
  net.last.send({ rows: [1, 2, 3] })
  assertEquals(store.getSnapshot().data, [1, 2, 3])

  net.last.fail()
  // Stale rows are honestly kept while reconnecting.
  assertEquals(store.getSnapshot().data, [1, 2, 3])
  assertEquals(store.getSnapshot().liveness, 'reconnecting')

  timer.fire()
  assertEquals(net.last.url, url)
  net.last.fireOpen()
  net.last.send({ rows: [9] })
  assertEquals(store.getSnapshot().data, [9])
})

Deno.test('close stops reconnection and drops listeners', () => {
  const net = new FakeNet()
  const timer = new FakeTimer()
  const { store } = collectStore(net, timer, revSubscription(0))
  net.last.fireOpen()
  net.last.fail()
  assertEquals(timer.pendingCount, 1)
  store.close()
  // Close cancels the pending reconnect and opens no new connection.
  assertEquals(timer.pendingCount, 0)
  assertEquals(net.streams.length, 1)
})

class MemoryViewerCache implements ViewerCache {
  readonly entries = new Map<string, unknown>()
  get<Value>(kind: string, key: string) {
    return Promise.resolve(
      structuredClone(this.entries.get(`${kind} ${key}`)) as Value | undefined,
    )
  }
  put(kind: string, key: string, value: unknown) {
    this.entries.set(`${kind} ${key}`, structuredClone(value))
    return Promise.resolve()
  }
}

class FakeNetwork implements Network {
  up = true
  private handler: (() => void) | null = null
  online = () => this.up
  onChange = (handler: () => void) => {
    this.handler = handler
    return () => {
      this.handler = null
    }
  }
  set(up: boolean) {
    this.up = up
    this.handler?.()
  }
}

function keptRevSubscription(from: number): Subscription<RevEvent> {
  return {
    ...revSubscription(from),
    retention: {
      kind: 'conversation',
      key: 'box',
      retain: (kept, event) => [...kept, event],
    },
  }
}

const tick = () => new Promise((resolve) => setTimeout(resolve, 0))

Deno.test('kept events paint before connecting, and the connection resumes after them', async () => {
  const net = new FakeNet()
  const timer = new FakeTimer()
  const cache = new MemoryViewerCache()
  await cache.put('conversation', 'box', [
    { rev: 3, path: '/a' },
    { rev: 4, path: '/b' },
  ])
  const store = observeStore<RevEvent[], RevEvent>({
    subscription: keptRevSubscription(0),
    fold: (data, event) => [...data, event],
    initial: [],
    open: net.open,
    timer,
    cache,
  })
  store.subscribe(() => {})
  assertEquals(net.urls, [])
  await tick()
  assertEquals(store.getSnapshot(), {
    data: [{ rev: 3, path: '/a' }, { rev: 4, path: '/b' }],
    liveness: 'reconnecting',
  })
  assertEquals(net.urls, ['/observe?from=4'])

  net.last.fireOpen()
  net.last.send({ rev: 5, path: '/c' })
  assertEquals(store.getSnapshot().data.length, 3)
  // Retained events are written once the save delay passes, not per event.
  assertEquals(timer.delays.filter((delay) => delay === 1_000), [1_000])
  // The first pending timer is the stream's stale deadline.
  timer.fire()
  timer.fire()
  assertEquals(cache.entries.get('conversation box'), [
    { rev: 3, path: '/a' },
    { rev: 4, path: '/b' },
    { rev: 5, path: '/c' },
  ])
})

Deno.test('offline tears the stream down at once; online reconnects without backoff', () => {
  const net = new FakeNet()
  const timer = new FakeTimer()
  const network = new FakeNetwork()
  const store = observeStore<RevEvent[], RevEvent>({
    subscription: revSubscription(0),
    fold: (data, event) => [...data, event],
    initial: [],
    open: net.open,
    timer,
    network,
  })
  store.subscribe(() => {})
  net.last.fireOpen()
  assertEquals(store.getSnapshot().liveness, 'live')

  network.set(false)
  assertEquals(net.last.closed, true)
  assertEquals(store.getSnapshot().liveness, 'reconnecting')
  assertEquals(timer.pendingCount, 0)

  network.set(true)
  assertEquals(net.streams.length, 2)
  net.last.fail()
  // Offline, a scheduled retry opens nothing.
  network.up = false
  timer.fire()
  assertEquals(net.streams.length, 2)
})

Deno.test('a transcript keeps its last generation, items only, within its byte cap', () => {
  const retention = directSubscription('s', 'shared').retention!
  let kept: SessionStreamEvent[] = []
  // Three UTF-8 bytes a character: each item is just over 300 KB stored.
  const item = (position: number): SessionStreamEvent => ({
    kind: 'item',
    generation: 2,
    position,
    item: { text: '中'.repeat(100_000) },
  } as unknown as SessionStreamEvent)
  kept = retention.retain(kept, { kind: 'reset', generation: 1 })
  kept = retention.retain(kept, item(0))
  kept = retention.retain(kept, { kind: 'reset', generation: 2 })
  assertEquals(kept, [{ kind: 'reset', generation: 2 }])
  for (let position = 0; position < 10; position++) {
    kept = retention.retain(kept, item(position))
  }
  kept = retention.retain(kept, {
    kind: 'delta',
    attemptId: 'a',
    text: 'x',
  } as SessionStreamEvent)
  assertEquals(kept.length, 11)

  const stored = bounded(kept, retention)
  assert(
    byteLength(JSON.stringify(stored)) <= transcriptBytes,
    'the entry fits its cap',
  )
  assertEquals(stored.length, 7)
  assertEquals(stored[0], { kind: 'reset', generation: 2 })
  assertEquals(stored[1], item(4))
  assertEquals(stored[6], item(9))
})

Deno.test('a conversation keeps its latest messages within its byte cap', () => {
  const retention = conversationSubscription('c', 'shared').retention!
  const message = (n: number) =>
    ({ n, text: 'x'.repeat(300_000) }) as unknown as ConversationMessagePayload
  const kept = [1, 2, 3, 4, 5].map(message)
  const stored = bounded(kept, retention)
  assert(
    byteLength(JSON.stringify(stored)) <= conversationBytes,
    'the entry fits its cap',
  )
  assertEquals(stored.map((entry) => entry.n), [3, 4, 5])
})
