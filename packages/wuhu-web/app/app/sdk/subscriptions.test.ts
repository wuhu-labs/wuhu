import { assertEquals } from 'jsr:@std/assert@1'
import { observeStore, realTimer } from './observe.ts'
import { openAuthorizedStream } from './sse.ts'
import { foldDirect, initialDirectState } from '~/lib/transcript-fold'
import { directSubscription } from './subscriptions.ts'

Deno.test('paged transcript stream pins generation, exact head and encoded Claude history epoch', () => {
  const subscription = directSubscription('stable-session', 'shared')
  assertEquals(
    subscription.history!.url(4, 999, 'projection / +'),
    '/v1/session/stable-session/direct?paged=true&generation=4&position=999&epoch=projection%20%2F%20%2B',
  )
  assertEquals(
    subscription.history!.url(4, -1, null),
    '/v1/session/stable-session/direct?paged=true&generation=4&position=-1',
  )
})

function request<T>(result: T) {
  const pending: { result: T; onsuccess?: () => void } = { result }
  queueMicrotask(() => pending.onsuccess?.())
  return pending
}

Deno.test('empty wire page adapter opens after -1 and accepts the first live committed entry', async () => {
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
        {
          generation: 7,
          entries: [],
          origins: [],
          before: null,
          hasEarlier: false,
        },
        {
          generation: 7,
          historyEpoch: 'claude-ready-empty',
          entries: [],
          origins: [],
          before: null,
          hasEarlier: false,
          headPosition: null,
        },
      ]
    ) {
      const urls: string[] = []
      let controller: ReadableStreamDefaultController<Uint8Array> | null = null
      globalThis.fetch = (input: RequestInfo | URL, init?: RequestInit) => {
        const url = String(input)
        urls.push(url)
        if (url.includes('/transcript/page')) {
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
        subscription: directSubscription('empty', 'shared'),
        initial: initialDirectState,
        fold: foldDirect,
        open: openAuthorizedStream,
        timer: realTimer,
      })
      try {
        store.subscribe(() => {})
        for (let i = 0; i < 40; i++) await Promise.resolve()
        assertEquals(urls, [
          '/v1/session/empty/transcript/page?limit=200',
          `/v1/session/empty/direct?paged=true&generation=7&position=-1${
            'historyEpoch' in wire ? '&epoch=claude-ready-empty' : ''
          }`,
        ])
        assertEquals(store.getSnapshot().liveness, 'live')
        const event = {
          kind: 'item',
          generation: 7,
          position: 0,
          item: {
            assistant: {
              _0: {
                id: 'new-entry',
                timestamp: 0,
                content: [{ text: { text: 'first live entry' } }],
                stopReason: 'end_turn',
                usage: { input_tokens: 0, output_tokens: 0, total_tokens: 0 },
              },
            },
          },
        }
        controller!.enqueue(
          new TextEncoder().encode(`data: ${JSON.stringify(event)}\n\n`),
        )
        for (let i = 0; i < 10; i++) await Promise.resolve()
        assertEquals(store.getSnapshot().data.items.get(0)?.kind, 'assistant')
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
