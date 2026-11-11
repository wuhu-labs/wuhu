import { assertEquals } from 'jsr:@std/assert@1'
import { observeStore, realTimer } from './observe.ts'
import { openAuthorizedStream } from './sse.ts'
import { foldLines, initialLines } from '~/lib/transcript-lines'
import { linesSubscription } from './subscriptions.ts'

Deno.test('a lines stream pins the generation and the head it resumes after', () => {
  const subscription = linesSubscription('stable-session', 'shared')
  assertEquals(
    subscription.history!.url(4, 999, null),
    '/v1/session/stable-session/lines?generation=4&after=999',
  )
  assertEquals(
    subscription.history!.url(4, -1, null),
    '/v1/session/stable-session/lines?generation=4&after=-1',
  )
})

Deno.test('a prompt line is pinned at its position, whatever the head', () => {
  const history = linesSubscription('s', 'shared').history!
  const line = (key: string, position: number, prompt: boolean) => ({
    kind: 'line' as const,
    generation: 1,
    line: { position, at: 0, role: 'user' as const, key, prompt, message: {} },
  })
  assertEquals(history.position(line('group', 1, true)), 1)
  assertEquals(history.pinned?.(line('group', 1, true)), true)
  assertEquals(history.pinned?.(line('message:m', 5, false)), false)
})

function request<T>(result: T) {
  const pending: { result: T; onsuccess?: () => void } = { result }
  queueMicrotask(() => pending.onsuccess?.())
  return pending
}

Deno.test('an empty lines page opens after -1 and accepts the first live line', async () => {
  const previousFetch = globalThis.fetch
  const previousDatabase = globalThis.indexedDB
  globalThis.indexedDB = {
    open: () =>
      request({
        transaction: () => ({
          objectStore: () => ({ get: () => request(null) }),
        }),
        close() {},
      }),
  } as unknown as IDBFactory
  try {
    for (
      const wire of [
        { generation: 7, lines: [], hasEarlier: false },
      ]
    ) {
      const urls: string[] = []
      let controller: ReadableStreamDefaultController<Uint8Array> | null = null
      globalThis.fetch = (input: RequestInfo | URL, init?: RequestInit) => {
        const url = String(input)
        urls.push(url)
        if (url.includes('/lines/page')) {
          return Promise.resolve(Response.json(wire))
        }
        const body = new ReadableStream<Uint8Array>({
          start(opened) {
            controller = opened
            init?.signal?.addEventListener('abort', () => opened.close(), {
              once: true,
            })
          },
        })
        return Promise.resolve(
          new Response(body, {
            headers: { 'content-type': 'text/event-stream' },
          }),
        )
      }
      const store = observeStore({
        subscription: linesSubscription('empty', 'shared'),
        initial: initialLines,
        fold: foldLines,
        open: openAuthorizedStream,
        timer: realTimer,
      })
      try {
        store.subscribe(() => {})
        for (let i = 0; i < 40; i++) await Promise.resolve()
        assertEquals(urls, [
          '/v1/session/empty/lines/page?limit=200',
          '/v1/session/empty/lines?generation=7&after=-1',
        ])
        assertEquals(store.getSnapshot().liveness, 'live')
        const event = {
          kind: 'line',
          generation: 7,
          line: {
            position: 3,
            at: 0,
            role: 'assistant',
            key: 'attempt:new-entry',
            prompt: false,
            message: {
              assistant: { content: [{ text: { text: 'first live entry' } }] },
            },
          },
        }
        controller!.enqueue(
          new TextEncoder().encode(`data: ${JSON.stringify(event)}\n\n`),
        )
        for (let i = 0; i < 10; i++) await Promise.resolve()
        assertEquals(
          store.getSnapshot().data.lines.map((line) => line.key),
          ['attempt:new-entry'],
        )
        assertEquals(store.getSnapshot().history?.hasEarlier, false)
      } finally {
        store.close()
      }
    }
  } finally {
    globalThis.fetch = previousFetch
    globalThis.indexedDB = previousDatabase
  }
})
