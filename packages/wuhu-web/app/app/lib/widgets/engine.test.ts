import { assertEquals, assertRejects } from 'jsr:@std/assert@1'
import { QuickJSFFI } from '@jitl/quickjs-ng-wasmfile-release-sync/ffi'
import {
  newQuickJSWASMModuleFromVariant,
  newVariant,
} from 'quickjs-emscripten-core'
import {
  defaultLimits,
  runScript,
  ScriptError,
  type ScriptHostCalls,
} from './engine.ts'

// The engine the page loads, from the same injected files, without vite.
const engine = await newQuickJSWASMModuleFromVariant(newVariant({
  type: 'sync',
  importFFI: () => Promise.resolve(QuickJSFFI),
  importModuleLoader: () =>
    import('./quickjs/emscripten-module.browser.mjs').then((loaded) =>
      loaded.default
    ),
}, {
  wasmModule: () =>
    Deno.readFile(
      new URL('./quickjs/emscripten-module.wasm', import.meta.url),
    ).then((bytes) => WebAssembly.compile(bytes)),
}))

function host() {
  const asked: string[][] = []
  const calls: ScriptHostCalls = {
    query: (sql, params) => {
      asked.push(['query', sql, params])
      return Promise.resolve('[{"n":1}]')
    },
    fetch: (request) => {
      asked.push(['fetch', JSON.parse(request).url])
      return Promise.resolve(
        JSON.stringify({
          status: 200,
          statusText: 'OK',
          headers: [],
          body: 'up',
        }),
      )
    },
  }
  return { asked, calls }
}

const run = (
  code: string,
  calls: ScriptHostCalls,
  props: unknown = {},
  limits = defaultLimits,
  signal?: AbortSignal,
) => runScript(engine, code, '/w.widget.jsx', props, calls, limits, signal)

Deno.test('a script sees query and the proxied fetch, and nothing ambient', async () => {
  const { asked, calls } = host()
  const result = await run(
    `export default async () => ({
      ambient: [typeof setTimeout, typeof setInterval, typeof document,
        typeof window, typeof localStorage, typeof XMLHttpRequest,
        typeof std, typeof os, typeof __wuhu_query, typeof __wuhu_fetch],
      fetched: await (await fetch('http://pool.test/summary')).text(),
    })`,
    calls,
  )
  assertEquals(JSON.parse(result.value), {
    ambient: Array(10).fill('undefined'),
    fetched: 'up',
  })
  assertEquals(asked, [['fetch', 'http://pool.test/summary']])
})

Deno.test('props reach the default export, sizes and bound parameters come back', async () => {
  const { asked, calls } = host()
  const result = await run(
    `export const sizes = ['small']
    export default async ({ size }) =>
      ({ size, rows: await query\`SELECT n FROM t WHERE x = \${1} AND y = \${'a'}\` })`,
    calls,
    { size: 'small' },
  )
  assertEquals(result.sizes, ['small'])
  assertEquals(JSON.parse(result.value), { size: 'small', rows: [{ n: 1 }] })
  assertEquals(asked, [[
    'query',
    'SELECT n FROM t WHERE x = ? AND y = ?',
    '[1,"a"]',
  ]])
})

Deno.test('a function in the output is marked, never run', async () => {
  const { calls } = host()
  const result = await run(
    `export default () => h(Figure, { value: 1, to: () => 'x' })`,
    calls,
  )
  assertEquals(JSON.parse(result.value), {
    $element: 'Figure',
    props: { value: 1, to: { $function: 'to' } },
  })
})

Deno.test('a busy loop and a host that never answers both time out', async () => {
  const { calls } = host()
  const limits = { sliceMs: 50, totalMs: 300, memoryBytes: 32 << 20 }
  await assertRejects(
    () => run(`export default () => { for (;;) {} }`, calls, {}, limits),
    ScriptError,
    '/w.widget.jsx: timed out',
  )
  await assertRejects(
    () =>
      run(
        `export default () => query\`SELECT 1\``,
        {
          ...calls,
          query: () => new Promise(() => {}),
        },
        {},
        limits,
      ),
    ScriptError,
    '/w.widget.jsx: timed out',
  )
})

Deno.test('a run waiting on the host keeps running past a slice', async () => {
  const { calls } = host()
  const limits = { sliceMs: 50, totalMs: 2_000, memoryBytes: 32 << 20 }
  const result = await run(
    `export default async () => (await query\`SELECT 1\`).length`,
    {
      ...calls,
      query: () =>
        new Promise((resolve) => setTimeout(() => resolve('[1,2]'), 200)),
    },
    {},
    limits,
  )
  assertEquals(result.value, '2')
})

Deno.test('a cancelled run stops', async () => {
  const { calls } = host()
  const abort = new AbortController()
  abort.abort()
  await assertRejects(
    () => run(`export default () => 1`, calls, {}, defaultLimits, abort.signal),
    ScriptError,
    'cancelled',
  )
})
