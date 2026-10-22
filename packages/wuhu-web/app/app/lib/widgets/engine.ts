import type {
  QuickJSContext,
  QuickJSDeferredPromise,
  QuickJSHandle,
  QuickJSWASMModule,
} from 'quickjs-emscripten-core'
import { prelude, serialize } from './prelude.ts'

// What a run may ask of the page: rows for a query, an answer for a fetch,
// each as JSON text.
export interface ScriptHostCalls {
  query(sql: string, params: string): Promise<string>
  fetch(request: string): Promise<string>
}

export interface ScriptRun {
  // The default export's result as JSON text.
  value: string
  // `export const sizes`, when the module declares it.
  sizes: unknown
}

export interface ScriptLimits {
  // Uninterrupted interpreter time for one slice of work.
  sliceMs: number
  // The whole run, waiting on the host included.
  totalMs: number
  memoryBytes: number
}

export const defaultLimits: ScriptLimits = {
  sliceMs: 1_000,
  totalMs: 30_000,
  memoryBytes: 32 << 20,
}

export class ScriptError extends Error {}

// One run in a fresh runtime: the prelude, then the module, then its default
// export called with props, awaited. Nothing survives the run.
export async function runScript(
  engine: QuickJSWASMModule,
  code: string,
  file: string,
  props: unknown,
  host: ScriptHostCalls,
  limits: ScriptLimits = defaultLimits,
  signal?: AbortSignal,
): Promise<ScriptRun> {
  if (signal?.aborted) throw new ScriptError(`${file}: cancelled`)
  const deadline = performance.now() + limits.totalMs
  const runtime = engine.newRuntime()
  runtime.setMemoryLimit(limits.memoryBytes)
  runtime.setMaxStackSize(512 << 10)
  let sliceEnd = 0
  runtime.setInterruptHandler(() => performance.now() > sliceEnd)
  const slice = <T>(work: () => T): T => {
    sliceEnd = performance.now() + limits.sliceMs
    return work()
  }
  const context = runtime.newContext()
  const handles: QuickJSHandle[] = []
  const deferreds = new Set<QuickJSDeferredPromise>()
  let alive = true
  const keep = (handle: QuickJSHandle) => {
    handles.push(handle)
    return handle
  }
  const failure = (error: QuickJSHandle): ScriptError => {
    const dumped = slice(() => context.dump(error))
    error.dispose()
    if (dumped?.message === 'interrupted') {
      return new ScriptError(`${file}: timed out`)
    }
    const message = typeof dumped === 'object' && dumped != null &&
        'message' in dumped
      ? String(dumped.message)
      : String(dumped)
    return new ScriptError(`${file}: ${message}`)
  }
  const unwrap = (
    result: ReturnType<QuickJSContext['evalCode']>,
  ): QuickJSHandle => {
    if (result.error) throw failure(result.error)
    return keep(result.value)
  }
  const pump = () => {
    if (!alive) return
    const done = slice(() => runtime.executePendingJobs())
    if (done.error) {
      // A throw inside a job rejects the promise it belongs to; the run
      // reads it there.
      done.error.dispose()
    }
  }
  const hostFunction = (
    name: string,
    call: (...args: string[]) => Promise<string>,
  ) => {
    const fn = context.newFunction(name, (...args) => {
      const deferred = context.newPromise()
      deferreds.add(deferred)
      const texts = args.map((arg) => context.getString(arg))
      call(...texts).then(
        (text) => {
          if (!alive) return
          const answer = context.newString(text)
          slice(() => deferred.resolve(answer))
          answer.dispose()
          pump()
        },
        (error: unknown) => {
          if (!alive) return
          const refused = context.newError(
            error instanceof Error ? error.message : String(error),
          )
          slice(() => deferred.reject(refused))
          refused.dispose()
          pump()
        },
      )
      return deferred.handle
    })
    context.setProp(context.global, name, fn)
    fn.dispose()
  }
  try {
    hostFunction('__wuhu_query', (sql, params) => host.query(sql!, params!))
    hostFunction('__wuhu_fetch', (request) => host.fetch(request!))
    unwrap(slice(() => context.evalCode(prelude, 'prelude.js')))
    const evaluated = unwrap(
      slice(() => context.evalCode(code, file, { type: 'module' })),
    )
    const namespace = await settle(evaluated)
    const sizes = slice(() =>
      context.dump(keep(context.getProp(namespace, 'sizes')))
    )
    const main = keep(slice(() => context.getProp(namespace, 'default')))
    if (context.typeof(main) !== 'function') {
      throw new ScriptError(`${file}: the default export is not a function`)
    }
    const argument = unwrap(
      slice(() => context.evalCode(`(${JSON.stringify(props)})`, 'props.js')),
    )
    const returned = unwrap(
      slice(() => context.callFunction(main, context.undefined, argument)),
    )
    const value = await settle(returned)
    const writer = unwrap(
      slice(() => context.evalCode(serialize, 'serialize.js')),
    )
    const text = unwrap(
      slice(() => context.callFunction(writer, context.undefined, value)),
    )
    return { value: context.getString(text), sizes }
  } finally {
    alive = false
    for (const deferred of deferreds) deferred.dispose()
    for (const handle of handles) if (handle.alive) handle.dispose()
    context.dispose()
    runtime.dispose()
  }

  // A promise, or a module still evaluating, settles as the host answers,
  // by the run's one deadline.
  async function settle(handle: QuickJSHandle): Promise<QuickJSHandle> {
    if (signal?.aborted) throw new ScriptError(`${file}: cancelled`)
    const settled = slice(() => context.resolvePromise(handle))
    pump()
    let timer: ReturnType<typeof setTimeout> | undefined
    const late = new Promise<never>((_, reject) => {
      timer = setTimeout(
        () => reject(new ScriptError(`${file}: timed out`)),
        Math.max(0, deadline - performance.now()),
      )
    })
    let onAbort = () => {}
    const aborted = new Promise<never>((_, reject) => {
      onAbort = () => reject(new ScriptError(`${file}: cancelled`))
      signal?.addEventListener('abort', onAbort, { once: true })
    })
    try {
      return unwrap(await Promise.race([settled, late, aborted]))
    } finally {
      clearTimeout(timer)
      signal?.removeEventListener('abort', onAbort)
    }
  }
}
