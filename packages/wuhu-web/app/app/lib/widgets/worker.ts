import { runScript } from './engine.ts'
import type { FromWorker, ToWorker } from './protocol.ts'
import { quickJS } from './quickjs.ts'

// Scripts run here, off the main thread, each in its own QuickJS runtime.
const scope = self as unknown as {
  postMessage(message: FromWorker): void
  onmessage: ((event: MessageEvent<ToWorker>) => void) | null
}
const pending = new Map<
  string,
  { resolve: (text: string) => void; reject: (error: Error) => void }
>()
const runs = new Map<number, AbortController>()
let calls = 0

const post = (message: FromWorker) => scope.postMessage(message)

function ask(
  run: number,
  message: (call: number) => FromWorker,
): Promise<string> {
  const call = ++calls
  return new Promise((resolve, reject) => {
    pending.set(`${run}/${call}`, { resolve, reject })
    post(message(call))
  })
}

scope.onmessage = async ({ data }) => {
  switch (data.kind) {
    case 'answer':
    case 'refuse': {
      const key = `${data.run}/${data.call}`
      const waiting = pending.get(key)
      pending.delete(key)
      if (data.kind === 'answer') waiting?.resolve(data.text)
      else waiting?.reject(new Error(data.message))
      return
    }
    case 'cancel':
      runs.get(data.run)?.abort()
      for (const [key, waiting] of pending) {
        if (!key.startsWith(`${data.run}/`)) continue
        pending.delete(key)
        waiting.reject(new Error('cancelled'))
      }
      return
    case 'run': {
      const { run } = data
      const abort = new AbortController()
      runs.set(run, abort)
      try {
        const result = await runScript(
          await quickJS(),
          data.code,
          data.file,
          data.props,
          {
            query: (sql, params) =>
              ask(run, (call) => ({ kind: 'query', run, call, sql, params })),
            fetch: (request) =>
              ask(run, (call) => ({ kind: 'fetch', run, call, request })),
          },
          undefined,
          abort.signal,
        )
        post({ kind: 'done', run, value: result.value, sizes: result.sizes })
      } catch (error) {
        post({
          kind: 'failed',
          run,
          message: error instanceof Error ? error.message : String(error),
        })
      } finally {
        runs.delete(run)
      }
    }
  }
}
