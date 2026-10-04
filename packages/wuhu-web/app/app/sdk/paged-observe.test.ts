import {
  type EventStream,
  type Network,
  observeStore,
  type Timer,
} from './observe.ts'
import { ApiError } from './errors.ts'
import type { ViewerCache } from './open-cache.ts'
import {
  boundHistory,
  emptyWindow,
  type HistoryPage,
  mergePage,
  visibleHistory,
} from './history-window.ts'

const equal = (a: unknown, b: unknown) => {
  if (JSON.stringify(a) !== JSON.stringify(b)) {
    throw new Error(`expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`)
  }
}
const check = (a: unknown) => {
  if (!a) throw new Error('assertion failed')
}
const tick = async () => {
  for (let i = 0; i < 8; i++) await Promise.resolve()
}
type Event =
  | { kind: 'item'; generation: number; position: number; body: string }
  | { kind: 'reset'; generation: number }
  | { kind: 'delta'; body: string }
const item = (position: number, generation = 1): Event => ({
  kind: 'item',
  position,
  generation,
  body: String(position),
})
function page(
  low: number,
  high: number,
  hasEarlier = true,
  generation = 1,
): HistoryPage<Event> {
  return {
    generation,
    historyEpoch: null,
    entries: Array.from(
      { length: Math.max(0, high - low + 1) },
      (_, i) => ({ position: low + i, event: item(low + i, generation) }),
    ),
    origins: [],
    before: high < low ? null : low,
    hasEarlier,
    headPosition: high,
  }
}
class Clock implements Timer {
  tasks: { delay: number; run: () => void; cancelled: boolean }[] = []
  schedule(delay: number, run: () => void) {
    const task = { delay, run, cancelled: false }
    this.tasks.push(task)
    return () => {
      task.cancelled = true
    }
  }
  fire(delay: number) {
    const task = this.tasks.find((task) =>
      !task.cancelled && task.delay === delay
    )
    if (!task) throw new Error(`no timer ${delay}`)
    task.cancelled = true
    task.run()
  }
}
class Stream implements EventStream {
  closed = false
  opened = () => {}
  message = (_raw: string) => {}
  activity = () => {}
  error = () => {}
  constructor(readonly url: string) {}
  onOpen(handler: () => void) {
    this.opened = handler
  }
  onMessage(handler: (raw: string) => void) {
    this.message = handler
  }
  onActivity(handler: () => void) {
    this.activity = handler
  }
  onError(handler: () => void) {
    this.error = handler
  }
  close() {
    this.closed = true
  }
  send(event: Event) {
    this.message(JSON.stringify(event))
  }
}
class Cache implements ViewerCache {
  value: unknown
  get<T>() {
    return Promise.resolve(this.value as T | undefined)
  }
  put(_kind: string, _key: string, value: unknown) {
    this.value = structuredClone(value)
    return Promise.resolve()
  }
}
function fixture(cache?: Cache) {
  const clock = new Clock()
  const streams: Stream[] = []
  const requests: {
    before: number | null
    generation: number | null
    signal: AbortSignal
    historyEpoch: string | null
    resolve: (page: HistoryPage<Event>) => void
    reject: (error: unknown) => void
  }[] = []
  let online = true
  let networkChange = () => {}
  const network: Network = {
    online: () => online,
    onChange: (handler) => {
      networkChange = handler
      return () => {}
    },
  }
  const store = observeStore<
    { generation: number; rows: number[]; text: string },
    Event
  >({
    subscription: {
      from: null,
      url: () => '/direct',
      cursorOf: () => null,
      history: {
        page: (before, generation, signal, historyEpoch) =>
          new Promise((resolve, reject) =>
            requests.push({
              before,
              generation,
              signal,
              historyEpoch,
              resolve,
              reject,
            })
          ),
        url: (generation, position, historyEpoch) =>
          `/direct?paged=true&generation=${generation}&position=${position}${
            historyEpoch ? `&epoch=${historyEpoch}` : ''
          }`,
        generation: (event) => event.kind === 'delta' ? null : event.generation,
        position: (event) => event.kind === 'item' ? event.position : null,
        isReset: (event) => event.kind === 'reset',
        reset: (generation) => ({ kind: 'reset', generation }),
      },
      retention: {
        kind: 'transcript',
        key: 's',
        maxBytes: 2000,
        retain: (events) => events,
      },
    },
    initial: { generation: 0, rows: [], text: '' },
    fold: (state, event) =>
      event.kind === 'reset'
        ? { generation: event.generation, rows: [], text: '' }
        : event.kind === 'delta'
        ? { ...state, text: state.text + event.body }
        : {
          ...state,
          rows: [...new Set([...state.rows, event.position])].sort((a, b) =>
            a - b
          ),
        },
    open: (url) => {
      const stream = new Stream(url)
      streams.push(stream)
      return stream
    },
    timer: clock,
    cache,
    network,
  })
  const unsubscribe = store.subscribe(() => {})
  return {
    store,
    clock,
    streams,
    requests,
    unsubscribe,
    network: (up: boolean) => {
      online = up
      networkChange()
    },
  }
}

Deno.test('tail paints bounded page, then stream starts at exact head and deduplicates race', async () => {
  const f = fixture()
  await tick()
  equal(f.requests[0]!.before, null)
  f.requests[0]!.resolve(page(800, 999))
  await tick()
  equal(f.store.getSnapshot().data.rows.length, 200)
  equal(f.streams[0]!.url, '/direct?paged=true&generation=1&position=999')
  f.streams[0]!.opened()
  f.streams[0]!.send(item(999))
  f.streams[0]!.send(item(1000))
  f.streams[0]!.send(item(1000))
  equal(f.store.getSnapshot().data.rows.length, 201)
  equal(f.requests.length, 1)
  f.store.close()
})

Deno.test('backfill is single-flight, merges overlap, keeps forward head and active text', async () => {
  const f = fixture()
  await tick()
  f.requests[0]!.resolve(page(8, 9))
  await tick()
  f.streams[0]!.send({ kind: 'delta', body: 'writing' })
  f.store.getSnapshot().history!.loadOlder()
  f.store.getSnapshot().history!.loadOlder()
  equal(f.requests.length, 2)
  equal(f.requests[1]!.before, 8)
  equal(f.requests[1]!.generation, 1)
  f.streams[0]!.send(item(10))
  f.requests[1]!.resolve(page(5, 8))
  await tick()
  equal(f.store.getSnapshot().data, {
    generation: 1,
    rows: [5, 6, 7, 8, 9, 10],
    text: 'writing',
  })
  f.streams[0]!.error()
  f.clock.fire(250)
  await tick()
  f.requests[2]!.resolve(page(9, 10))
  await tick()
  check(f.streams[1]!.url.endsWith('position=10'))
  equal(f.store.getSnapshot().data.rows, [5, 6, 7, 8, 9, 10])
  f.store.close()
})

Deno.test('warm range missing zero paints, then long-offline gap hides cached lower range until bridged', async () => {
  const cache = new Cache()
  cache.value = mergePage(emptyWindow(), page(80, 99), null)
  const f = fixture(cache)
  await tick()
  equal(f.store.getSnapshot().data.rows.length, 20)
  f.requests[0]!.resolve(page(180, 199))
  await tick()
  equal(f.store.getSnapshot().data.rows[0], 180)
  equal(f.store.getSnapshot().history!.gap, true)
  f.store.getSnapshot().history!.loadOlder()
  f.requests[1]!.resolve(page(100, 179))
  await tick()
  // No inferred continuity: 99->100 is not sufficient until a bounded page crosses that boundary.
  equal(f.store.getSnapshot().data.rows[0], 100)
  f.store.getSnapshot().history!.loadOlder()
  f.requests[2]!.resolve(page(80, 99))
  await tick()
  equal(f.store.getSnapshot().data.rows[0], 80)
  equal(f.store.getSnapshot().history!.gap, false)
  f.store.close()
})

Deno.test('same generation paged reset clears retained ranges before bounded rebootstrap', async () => {
  const f = fixture()
  await tick()
  f.requests[0]!.resolve(page(8, 9))
  await tick()
  f.store.getSnapshot().history!.loadOlder()
  f.streams[0]!.send({ kind: 'reset', generation: 1 })
  await tick()
  check(f.requests[1]!.signal.aborted)
  check(f.streams[0]!.closed)
  equal(f.requests[2]!.before, null)
  f.requests[1]!.resolve(page(0, 7, false))
  await tick()
  equal(f.store.getSnapshot().data.rows, [])
  f.requests[2]!.resolve(page(9, 10))
  await tick()
  equal(f.store.getSnapshot().data.rows, [9, 10])
  f.store.close()
})

Deno.test('new generation reset clears old rows, cancels backfill and rejects stale page and stream', async () => {
  const f = fixture()
  await tick()
  f.requests[0]!.resolve(page(8, 9))
  await tick()
  f.store.getSnapshot().history!.loadOlder()
  f.streams[0]!.send({ kind: 'reset', generation: 2 })
  await tick()
  equal(f.store.getSnapshot().data.rows, [])
  check(f.requests[1]!.signal.aborted)
  f.requests[2]!.resolve(page(20, 21, true, 2))
  await tick()
  f.requests[1]!.resolve(page(0, 7, false))
  f.streams[0]!.send(item(10))
  f.streams[1]!.send(item(22, 1))
  await tick()
  equal(f.store.getSnapshot().data.rows, [20, 21])
  equal(f.store.getSnapshot().data.generation, 2)
  f.store.close()
})

Deno.test('generationChanged backward error reboots instead of silently using new generation', async () => {
  const f = fixture()
  await tick()
  f.requests[0]!.resolve(page(8, 9))
  await tick()
  f.store.getSnapshot().history!.loadOlder()
  f.requests[1]!.reject(
    new ApiError(409, { code: 'generationChanged', message: 'changed' }),
  )
  await tick()
  equal(f.requests[2]!.before, null)
  equal(f.store.getSnapshot().data.rows, [])
  f.requests[2]!.resolve(page(0, 1, false, 2))
  await tick()
  equal(f.store.getSnapshot().data.generation, 2)
  f.store.close()
})

Deno.test('failed older page leaves rows and live stream usable; retry and exhaustion stop further work', async () => {
  const f = fixture()
  await tick()
  f.requests[0]!.resolve(page(8, 9))
  await tick()
  f.store.getSnapshot().history!.loadOlder()
  f.requests[1]!.reject(new Error('offline'))
  await tick()
  equal(f.store.getSnapshot().history!.status, 'error')
  f.streams[0]!.send(item(10))
  equal(f.store.getSnapshot().data.rows, [8, 9, 10])
  f.store.getSnapshot().history!.retry()
  equal(f.requests[2]!.before, 8)
  f.requests[2]!.resolve(page(0, 7, false))
  await tick()
  equal(f.store.getSnapshot().history!.hasEarlier, false)
  f.store.getSnapshot().history!.loadOlder()
  equal(f.requests.length, 3)
  f.store.close()
})

Deno.test('empty and short page do not initiate automatic history cascade', async () => {
  for (const response of [page(0, -1, false), page(9, 9)]) {
    const f = fixture()
    await tick()
    f.requests[0]!.resolve(response)
    await tick()
    equal(f.requests.length, 1)
    equal(f.streams.length, 1)
    f.store.close()
  }
})

Deno.test('Preparing retries capped 250ms at same boundary and is cancellable', async () => {
  const f = fixture()
  await tick()
  for (let i = 0; i < 4; i++) {
    f.requests[i]!.reject(
      new ApiError(503, { code: 'transcriptPreparing', message: 'preparing' }),
    )
    await tick()
    equal(f.store.getSnapshot().history!.status, 'preparing')
    f.clock.fire(250)
    await tick()
  }
  f.store.close()
  check(f.requests[4]!.signal.aborted)
  f.requests[4]!.resolve(page(0, 1, false))
  await tick()
  equal(f.streams.length, 0)
})

Deno.test('network reconnect aborts older page and refreshes only tail; stale timeout does too', async () => {
  const f = fixture()
  await tick()
  f.requests[0]!.resolve(page(8, 9))
  await tick()
  f.streams[0]!.opened()
  f.store.getSnapshot().history!.loadOlder()
  f.network(false)
  check(f.requests[1]!.signal.aborted)
  f.network(true)
  await tick()
  equal(f.requests[2]!.before, null)
  f.requests[2]!.resolve(page(9, 10))
  await tick()
  f.streams[1]!.opened()
  f.store.getSnapshot().history!.loadOlder()
  f.clock.fire(45000)
  check(f.requests[3]!.signal.aborted)
  f.clock.fire(250)
  await tick()
  equal(f.requests[4]!.before, null)
  f.store.close()
})

Deno.test('disposal and StrictMode unsubscribe/resubscribe cannot accept old responses', async () => {
  const f = fixture()
  await tick()
  f.unsubscribe()
  check(f.requests[0]!.signal.aborted)
  f.store.subscribe(() => {})
  await tick()
  f.requests[0]!.resolve(page(0, 7, false))
  await tick()
  equal(f.streams.length, 0)
  f.requests[1]!.resolve(page(8, 9))
  await tick()
  equal(f.store.getSnapshot().data.rows, [8, 9])
  f.store.close()
})

Deno.test('old unversioned cache is discarded, never used as a cursor or full replay trigger', async () => {
  const cache = new Cache()
  cache.value = [item(0), item(1)]
  const f = fixture(cache)
  await tick()
  equal(f.store.getSnapshot().data.rows, [])
  equal(f.requests[0]!.before, null)
  f.store.close()
})

Deno.test('cache eviction adjusts ranges and exhaustion; origins do not become loaded records', () => {
  const p = page(0, 8, false)
  p.origins = [{ position: -1, event: item(-1) }]
  const window = mergePage(emptyWindow(), p, null)
  equal(visibleHistory(window).length, 9)
  const bounded = boundHistory(window, 600)
  check(JSON.stringify(bounded).length <= 600)
  check(bounded.entries.length < 9)
  equal(bounded.ranges[0]?.hasEarlier, true)
  equal(bounded.origins.length, 1)
})

Deno.test('sparse message ordinal pages join by exclusive request boundary not arithmetic', () => {
  const tail = {
    ...page(100, 100),
    entries: [{ position: 100, event: item(100) }, {
      position: 900,
      event: item(900),
    }],
    headPosition: 900,
  }
  let window = mergePage(emptyWindow(), tail, null)
  window = mergePage(window, { ...page(10, 10, false), headPosition: 901 }, 100)
  equal(visibleHistory(window).map((entry) => entry.position), [10, 100, 900])
  equal(window.headPosition, 900)
  equal(window.ranges[0]!.hasEarlier, false)
})

Deno.test('same-generation canonical refresh replaces changed content at the same position', () => {
  const previous = mergePage(emptyWindow<Event>(), page(0, 1, false), null)
  const refreshed = page(0, 1, false)
  refreshed.entries[0] = {
    position: 0,
    event: {
      kind: 'item',
      generation: 1,
      position: 0,
      body: 'summary now ready',
    },
  }
  const merged = mergePage(previous, refreshed, null)
  equal(merged.entries[0]!.event, refreshed.entries[0]!.event)
})

Deno.test('changed epoch without Preparing clears same-generation cached lower ranges and origins', async () => {
  const cache = new Cache()
  const prior = page(80, 99)
  prior.historyEpoch = 'old'
  prior.origins = [{ position: 20, event: item(20) }]
  cache.value = mergePage(emptyWindow(), prior, null)
  const f = fixture(cache)
  await tick()
  equal(f.store.getSnapshot().data.rows[0], 80)
  const refreshed = page(180, 199)
  refreshed.historyEpoch = 'new'
  f.requests[0]!.resolve(refreshed)
  await tick()
  equal(f.store.getSnapshot().history!.gap, false)
  equal(f.store.getSnapshot().origins, [])
  equal(f.store.getSnapshot().history!.historyEpoch, 'new')
  check(f.streams[0]!.url.endsWith('&epoch=new'))
  f.store.getSnapshot().history!.loadOlder()
  equal(f.requests[1]!.historyEpoch, 'new')
  f.clock.fire(1000)
  equal((cache.value as { historyEpoch: string }).historyEpoch, 'new')
  f.store.close()
})

Deno.test('older response epoch mismatch forces fresh bootstrap instead of joining incompatible ordinals', async () => {
  const f = fixture()
  await tick()
  const initial = page(8, 9)
  initial.historyEpoch = 'old'
  f.requests[0]!.resolve(initial)
  await tick()
  f.store.getSnapshot().history!.loadOlder()
  const invalid = page(0, 7, false)
  invalid.historyEpoch = 'new'
  f.requests[1]!.resolve(invalid)
  await tick()
  equal(f.store.getSnapshot().data.rows, [])
  check(f.streams[0]!.closed)
  equal(f.requests[2]!.before, null)
  f.store.close()
})

Deno.test('in-flight older epoch response cannot resurrect old rows after a reconnect seed', async () => {
  const f = fixture()
  await tick()
  const initial = page(8, 9)
  initial.historyEpoch = 'old'
  f.requests[0]!.resolve(initial)
  await tick()
  f.store.getSnapshot().history!.loadOlder()
  f.streams[0]!.error()
  f.clock.fire(250)
  await tick()
  const refreshed = page(20, 21)
  refreshed.historyEpoch = 'new'
  f.requests[2]!.resolve(refreshed)
  await tick()
  const late = page(0, 7, false)
  late.historyEpoch = 'old'
  f.requests[1]!.resolve(late)
  await tick()
  equal(f.store.getSnapshot().data.rows, [20, 21])
  equal(f.store.getSnapshot().history!.historyEpoch, 'new')
  f.store.close()
})
