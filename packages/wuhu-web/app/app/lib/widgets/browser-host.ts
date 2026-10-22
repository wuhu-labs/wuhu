import type { QueryOutput } from '~/lib/contract.gen'
import {
  browserNetwork,
  type EventStream,
  observeStore,
  realTimer,
} from '~/sdk/observe'
import { errorDetail } from '~/sdk/errors'
import { inGroup, post, withAssertion } from '~/sdk/http'
import { openAuthorizedStream } from '~/sdk/sse'
import { sqlSubscription } from '~/sdk/subscriptions'
import type { ScriptHostCalls, ScriptRun } from './engine.ts'
import { type FetchAnswer, type HostIO, ScriptHost } from './host.ts'
import type { FromWorker, ToWorker } from './protocol.ts'

// One worker for the page; it loads QuickJS on its first run.
let worker: Worker | null = null
let runs = 0
const running = new Map<
  number,
  {
    calls: ScriptHostCalls
    resolve: (run: ScriptRun) => void
    reject: (error: Error) => void
  }
>()

function scriptWorker(): Worker {
  if (worker != null) return worker
  const started = new Worker(new URL('./worker.ts', import.meta.url), {
    type: 'module',
  })
  const send = (message: ToWorker) => started.postMessage(message)
  started.onmessage = ({ data }: MessageEvent<FromWorker>) => {
    const run = running.get(data.run)
    if (run == null) return
    switch (data.kind) {
      case 'query':
      case 'fetch': {
        const asked = data.kind === 'query'
          ? run.calls.query(data.sql, data.params)
          : run.calls.fetch(data.request)
        asked.then(
          (text) =>
            send({ kind: 'answer', run: data.run, call: data.call, text }),
          (error: unknown) =>
            send({
              kind: 'refuse',
              run: data.run,
              call: data.call,
              message: error instanceof Error ? error.message : String(error),
            }),
        )
        return
      }
      case 'done':
        running.delete(data.run)
        run.resolve({ value: data.value, sizes: data.sizes })
        return
      case 'failed':
        running.delete(data.run)
        run.reject(new Error(data.message))
    }
  }
  worker = started
  return started
}

function query(path: string, values: Record<string, string>): string {
  // Not URLSearchParams: the server keeps "+" literal.
  return `${path}?${
    Object.entries(values).map(([key, value]) =>
      `${key}=${encodeURIComponent(value)}`
    ).join('&')
  }`
}

// The store retries a dropped stream and stops at a refusal; the host
// hears the refusal too.
function refusals(stream: EventStream, refused: () => void): EventStream {
  return {
    onOpen: (handler) => stream.onOpen(handler),
    onMessage: (handler) => stream.onMessage(handler),
    onActivity: (handler) => stream.onActivity(handler),
    onError: (handler) =>
      stream.onError((status) => {
        handler(status)
        if (status === 400 || status === 422) refused()
      }),
    close: () => stream.close(),
  }
}

export function browserHostIO(group: string): HostIO {
  return {
    query: (sql, params) =>
      post<QueryOutput>(
        '/v1/tools/query',
        { sql, parameters: params },
        inGroup(group),
      ),
    observe(sql, params, receive, refused) {
      const store = observeStore<QueryOutput | null, QueryOutput>({
        subscription: {
          ...sqlSubscription(sql, group, params),
          stopOnRefusal: true,
        },
        fold: (_, output) => output,
        initial: null,
        open: (url) =>
          refusals(openAuthorizedStream(url, inGroup(group)), refused),
        timer: realTimer,
        network: browserNetwork,
      })
      const stop = store.subscribe(() => {
        const output = store.getSnapshot().data
        if (output != null) receive(output)
      })
      return () => {
        stop()
        store.close()
      }
    },
    async fetch(page, request): Promise<FetchAnswer> {
      const url = query('/v1/fetch', {
        url: request.url,
        method: request.method,
        headers: JSON.stringify(request.headers),
        page,
      })
      const response = await withAssertion((authorization) =>
        fetch(url, {
          method: 'POST',
          headers: { ...inGroup(group), ...authorization },
          body: request.body ?? undefined,
        })
      )
      const body = await response.text()
      if (response.headers.get('wuhu-fetch-result') !== 'upstream') {
        throw new Error(errorDetail(response.status, body).message)
      }
      return {
        status: response.status,
        statusText: response.statusText,
        headers: [...response.headers],
        body,
      }
    },
    run(file, code, props, calls) {
      const run = ++runs
      const done = new Promise<ScriptRun>((resolve, reject) => {
        running.set(run, { calls, resolve, reject })
      })
      scriptWorker().postMessage(
        { kind: 'run', run, code, file, props } satisfies ToWorker,
      )
      return {
        done,
        cancel() {
          const waiting = running.get(run)
          running.delete(run)
          scriptWorker().postMessage({ kind: 'cancel', run } satisfies ToWorker)
          waiting?.reject(new Error(`${file}: cancelled`))
        },
      }
    },
    now: () => Date.now(),
    schedule: (delayMs, run) => realTimer.schedule(delayMs, run),
  }
}

const hosts = new Map<string, ScriptHost>()

// One host per group, shared by every script shown from it.
export function scriptHost(group: string): ScriptHost {
  let host = hosts.get(group)
  if (host == null) {
    host = new ScriptHost(browserHostIO(group))
    hosts.set(group, host)
  }
  return host
}
