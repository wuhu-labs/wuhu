import { assertEquals } from 'jsr:@std/assert@1'
import {
  groupChangeSubscription,
  groupFeedActive,
  spaceScope,
} from './space-feeds.tsx'

Deno.test('account and space key the roster and file-revision provider', () => {
  const a = spaceScope({ principal: 'first', spaceId: 'space-a' })
  const b = spaceScope({ principal: 'first', spaceId: 'space-b' })
  const c = spaceScope({ principal: 'second', spaceId: 'space-a' })
  if (a === b || a === c || b === c) {
    throw new Error('scope leaked across account or space')
  }
  if (spaceScope({ spaceId: 'space-a' }) !== null) {
    throw new Error('account must be known before keying')
  }
})

Deno.test('member feeds stay open before discovery and with every sidebar hidden or absent; readable nonmember sidebars open feeds', () => {
  assertEquals(groupFeedActive(true, null), true)
  assertEquals(groupFeedActive(true, []), true)
  assertEquals(groupFeedActive(false, null), false)
  assertEquals(groupFeedActive(false, []), false)
  assertEquals(
    groupFeedActive(false, [{
      path: '/.sidebars/work.json',
      title: 'Work',
      sections: [],
    }]),
    true,
  )
})

Deno.test('actual group change subscription discovers a new nonmember sidebar and promotes to full feed without reload', async () => {
  const { SpaceServer } = await import('~/sdk/client')
  const { observeStore } = await import('~/sdk/observe')
  const { sidebarPaths } = await import('./sidebars.ts')
  const originalFetch = globalThis.fetch
  const originalDB = globalThis.indexedDB
  function request<T>(result: T) {
    const pending: { result: T; onsuccess?: () => void } = { result }
    queueMicrotask(() => pending.onsuccess?.())
    return pending
  }
  globalThis.indexedDB = {
    open: () =>
      request({
        transaction: () => ({
          objectStore: () => ({ get: () => request(null) }),
        }),
        close() {},
      }),
  } as unknown as IDBFactory
  let names: string[] = []
  globalThis.fetch = (_input, init) => {
    assertEquals(JSON.parse(String(init?.body)), { path: '/.sidebars' })
    assertEquals(
      (init?.headers as Record<string, string>)['wuhu-group'],
      'readable-nonmember',
    )
    return Promise.resolve(
      Response.json({
        entries: names.map((name) => ({
          name,
          kind: 'file',
          size: 0,
          token: name,
          mtime: 0,
        })),
      }),
    )
  }
  const client = new SpaceServer().client('readable-nonmember')
  let message: (data: string) => void = () => {}
  let closeStore = () => {}
  let opened = Promise.withResolvers<string>()
  let closes = 0
  const stop = client.list('/.sidebars')((listing) => {
    closeStore()
    const sidebars = sidebarPaths(listing).map((path) => ({
      path,
      title: path,
      script: true as const,
    }))
    const subscription = groupChangeSubscription(client, false, sidebars, 20)
    const store = observeStore({
      subscription,
      initial: 0,
      fold: (_value, event) => event.rev,
      onEvent: client.filesChanged,
      open: (url) => {
        opened.resolve(url)
        return {
          onOpen() {},
          onActivity() {},
          onError() {},
          onMessage(receive) {
            message = receive
          },
          close() {
            closes++
          },
        }
      },
      timer: { schedule: () => () => {} },
    })
    const unsubscribe = store.subscribe(() => {})
    closeStore = () => {
      unsubscribe()
      store.close()
    }
  }, (failure) => {
    throw failure
  })
  try {
    assertEquals(
      new URL(await opened.promise, 'https://space.test').searchParams.get(
        'glob',
      ),
      '/.sidebars/**',
    )
    opened = Promise.withResolvers<string>()
    names = ['new.sidebar.jsx']
    message(
      JSON.stringify({
        rev: 21,
        events: [{ kind: 'write', path: '/.sidebars/new.sidebar.jsx' }],
      }),
    )
    const full = new URL(await opened.promise, 'https://space.test')
    assertEquals(full.searchParams.get('glob'), '**')
    assertEquals(full.searchParams.get('from'), '20')
    assertEquals(full.searchParams.get('batch'), '1')
    assertEquals(closes, 1)
    opened = Promise.withResolvers<string>()
    names = []
    message(
      JSON.stringify({
        rev: 22,
        events: [{ kind: 'delete', path: '/.sidebars/new.sidebar.jsx' }],
      }),
    )
    assertEquals(
      new URL(await opened.promise, 'https://space.test').searchParams.get(
        'glob',
      ),
      '/.sidebars/**',
    )
    assertEquals(closes, 2)
  } finally {
    stop()
    closeStore()
    globalThis.fetch = originalFetch
    globalThis.indexedDB = originalDB
  }
})
