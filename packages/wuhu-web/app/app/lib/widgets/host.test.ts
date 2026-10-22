import { assertEquals, assertThrows } from 'jsr:@std/assert@1'
import type { ScriptHostCalls } from './engine.ts'
import {
  everyMs,
  type FetchRequest,
  type HostIO,
  type QueryResult,
  ScriptHost,
  type ScriptResult,
} from './host.ts'

// A host whose "scripts" are TypeScript functions over the same calls a
// QuickJS run makes, with a clock and timers the test moves.
function rig(
  script: (calls: ScriptHostCalls) => Promise<unknown>,
  options: { failFetch?: number } = {},
) {
  let now = 0
  const timers: { at: number; run: () => void }[] = []
  const live = new Map<string, (result: QueryResult) => void>()
  const refuse = new Map<string, () => void>()
  const tables = new Map<string, unknown[][]>([['SELECT n FROM t', [[1]]]])
  const fetched: FetchRequest[] = []
  let reads = 0
  let runs = 0
  const io: HostIO = {
    query: () => {
      reads++
      return Promise.reject(new Error('no such table: nowhere'))
    },
    observe(sql, _params, receive, refused) {
      live.set(sql, receive)
      refuse.set(sql, refused)
      if (tables.has(sql)) {
        queueMicrotask(() =>
          live.get(sql)?.({ columns: ['n'], rows: tables.get(sql)! })
        )
      }
      return () => live.delete(sql)
    },
    fetch(_page, request) {
      fetched.push(request)
      if (fetched.length === options.failFetch) {
        return Promise.reject(new Error('the pool is down'))
      }
      return Promise.resolve({
        status: 200,
        statusText: 'OK',
        headers: [],
        body: `answer ${fetched.length}`,
      })
    },
    run(_file, _code, _props, calls) {
      runs++
      return {
        done: script(calls).then((value) => ({
          value: JSON.stringify(value),
          sizes: undefined,
        })),
        cancel() {},
      }
    },
    now: () => now,
    schedule(delayMs, run) {
      const timer = { at: now + delayMs, run }
      timers.push(timer)
      return () => timers.splice(timers.indexOf(timer), 1)
    },
  }
  const results: ScriptResult[] = []
  const host = new ScriptHost(io)
  return {
    host,
    results,
    fetched,
    reads: () => reads,
    runs: () => runs,
    watch: (active = true, code = '') =>
      host.watch(
        { file: '/.widgets/w.widget.jsx', code, props: {}, active },
        (result) => results.push(result),
      ),
    change(sql: string, rows: unknown[][]) {
      tables.set(sql, rows)
      live.get(sql)?.({ columns: ['n'], rows })
    },
    refuse: (sql: string) => refuse.get(sql)?.(),
    async advance(ms: number) {
      now += ms
      for (const timer of timers.filter((timer) => timer.at <= now)) {
        timers.splice(timers.indexOf(timer), 1)
        timer.run()
      }
      await settle()
    },
    live,
  }
}

const fetchCall = (calls: ScriptHostCalls, init: Partial<FetchRequest> = {}) =>
  calls.fetch(JSON.stringify({
    url: 'http://pool.test/status',
    method: 'GET',
    headers: {},
    body: null,
    every: '10s',
    ...init,
  })).then((text) => JSON.parse(text))

const settle = () => new Promise((resolve) => setTimeout(resolve, 0))

Deno.test('a query rerun follows its rows, and the same output draws once', async () => {
  const r = rig(async (calls) => {
    const rows = JSON.parse(await calls.query('SELECT n FROM t', '[]'))
    return { big: rows[0].n > 1 }
  })
  r.watch()
  await settle()
  assertEquals(r.results, [{
    ok: true,
    value: { big: false },
    sizes: undefined,
  }])
  r.change('SELECT n FROM t', [[0]])
  await settle()
  assertEquals(r.runs(), 2)
  assertEquals(r.results.length, 1)
  r.change('SELECT n FROM t', [[5]])
  await settle()
  assertEquals(r.results.at(-1), {
    ok: true,
    value: { big: true },
    sizes: undefined,
  })
})

Deno.test('a fetch with every reruns when stale, and only on screen', async () => {
  const r = rig(async (calls) => (await fetchCall(calls)).body)
  const watching = r.watch(false)
  await settle()
  // Off screen a run that needs the network stops and draws nothing.
  assertEquals(r.fetched.length, 0)
  assertEquals(r.results, [])
  watching.setActive(true)
  await settle()
  assertEquals(r.results.map((result) => result.ok && result.value), [
    'answer 1',
  ])
  // `every` never goes under 30 s.
  await r.advance(29_000)
  assertEquals(r.fetched.length, 1)
  await r.advance(2_000)
  assertEquals(r.fetched.length, 2)
  watching.setActive(false)
  await r.advance(31_000)
  assertEquals(r.fetched.length, 2)
  watching.setActive(true)
  await settle()
  assertEquals(r.fetched.length, 3)
  assertEquals(r.results.at(-1), {
    ok: true,
    value: 'answer 3',
    sizes: undefined,
  })
  watching.stop()
  await r.advance(60_000)
  assertEquals(r.fetched.length, 3)
})

Deno.test('an off-screen rerun on a query change keeps what it drew and never fetches', async () => {
  const r = rig(async (calls) => {
    const rows = JSON.parse(await calls.query('SELECT n FROM t', '[]'))
    return `${rows[0].n} ${(await fetchCall(calls, { every: null })).body}`
  })
  const watching = r.watch()
  await settle()
  watching.setActive(false)
  r.change('SELECT n FROM t', [[2]])
  await settle()
  assertEquals(r.fetched.length, 1)
  assertEquals(r.results.map((result) => result.ok && result.value), [
    '1 answer 1',
  ])
  watching.setActive(true)
  await settle()
  assertEquals(r.results.at(-1), {
    ok: true,
    value: '2 answer 2',
    sizes: undefined,
  })
})

Deno.test('a fetch is GET or HEAD only', async () => {
  const r = rig(async (calls) => [
    (await fetchCall(calls, { method: 'POST', body: 'x' })).error,
    (await fetchCall(calls, { method: 'head' })).status,
  ])
  r.watch()
  await settle()
  assertEquals(r.results[0], {
    ok: true,
    value: ['fetch is GET or HEAD only, not POST', 200],
    sizes: undefined,
  })
  assertEquals(r.fetched.map((request) => request.method), ['HEAD'])
})

Deno.test('a failure lasts one run, an answer without every lasts one run, and a new version refetches', async () => {
  let call = 0
  const r = rig(async (calls) => {
    call++
    const every = call === 3 ? null : '1m'
    const first = await fetchCall(calls, { every })
    const again = await fetchCall(calls, { every })
    return [first.error ?? first.body, again.error ?? again.body]
  }, { failFetch: 1 })
  const first = r.watch()
  await settle()
  assertEquals(r.results.at(-1), {
    ok: true,
    value: ['the pool is down', 'the pool is down'],
    sizes: undefined,
  })
  first.stop()
  r.watch()
  await settle()
  assertEquals(r.fetched.length, 2)
  r.watch().stop()
  await settle()
  assertEquals(r.fetched.length, 3)
  r.watch()
  await settle()
  assertEquals(r.fetched.length, 3)
  r.watch(true, 'export default () => 2')
  await settle()
  assertEquals(r.fetched.length, 4)
})

Deno.test('a refused query fails the run with its message, from one read', async () => {
  const r = rig(async (calls) => {
    await calls.query('SELECT * FROM nowhere', '[]')
    return null
  })
  r.watch()
  await settle()
  r.refuse('SELECT * FROM nowhere')
  await settle()
  assertEquals(r.reads(), 1)
  assertEquals(r.results, [{ ok: false, message: 'no such table: nowhere' }])
  assertEquals([...r.live.keys()], [])
})

Deno.test('a query refused after it answered fails the run, and nobody holds it', async () => {
  const r = rig(async (calls) => {
    const rows = JSON.parse(await calls.query('SELECT n FROM t', '[]'))
    return { n: rows[0].n }
  })
  r.watch()
  await settle()
  assertEquals(r.results, [{ ok: true, value: { n: 1 }, sizes: undefined }])
  r.refuse('SELECT n FROM t')
  await settle()
  assertEquals(r.results.at(-1), {
    ok: false,
    message: 'no such table: nowhere',
  })
  assertEquals(r.runs(), 2)
  assertEquals([...r.live.keys()], [])
})

Deno.test('stopping lets a query still in flight go', async () => {
  const r = rig(async (calls) => {
    await calls.query('SELECT slow FROM t', '[]')
    return null
  })
  const watching = r.watch()
  await settle()
  assertEquals([...r.live.keys()], ['SELECT slow FROM t'])
  watching.stop()
  assertEquals([...r.live.keys()], [])
})

Deno.test('a stopped script lets its live queries go', async () => {
  const r = rig(async (calls) => {
    await calls.query('SELECT n FROM t', '[]')
    return null
  })
  const watching = r.watch()
  await settle()
  assertEquals([...r.live.keys()], ['SELECT n FROM t'])
  watching.stop()
  assertEquals([...r.live.keys()], [])
})

Deno.test('every is a duration with a 30 s floor', () => {
  assertEquals(everyMs(null), null)
  assertEquals(everyMs('1m'), 60_000)
  assertEquals(everyMs('5s'), 30_000)
  assertEquals(everyMs('2h'), 7_200_000)
  assertThrows(() => everyMs('soon'), Error, 'a duration')
})
