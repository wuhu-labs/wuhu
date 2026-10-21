import { type DiscoveredTree, TreeDiscovery } from './tree-discovery.ts'

function result<T>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((yes) => {
    resolve = yes
  })
  return { promise, resolve }
}

function equal(actual: unknown, expected: unknown) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    )
  }
}

Deno.test('cold unreachable discovery recovers on feed open and supplies its crawl revision as the new cursor', async () => {
  const loaded = result<DiscoveredTree>()
  let attempts = 0
  const discovery = new TreeDiscovery({
    kept: () => Promise.reject(new Error('cache unavailable')),
    load: () =>
      ++attempts === 1
        ? Promise.reject(new TypeError('server unreachable'))
        : Promise.resolve({ paths: new Map([['/note.txt', 'file']]), rev: 12 }),
  }, (tree) => {
    if (tree.from !== null) loaded.resolve(tree)
  })
  await discovery.restore()
  discovery.opened()
  const tree = await loaded.promise
  equal([...tree.paths], [['/note.txt', 'file']])
  equal(tree.from, 12)
  equal(tree.error, null)
  equal(attempts, 2)
  discovery.close()
})

Deno.test('a completed crawl supplies the exact cursor for the existing tree fold', async () => {
  const tree = result<DiscoveredTree>()
  const discovery = new TreeDiscovery({
    kept: () => Promise.resolve(undefined),
    load: () =>
      Promise.resolve({ paths: new Map([['/old.txt', 'file']]), rev: 10 }),
  }, tree.resolve)
  await discovery.restore()
  const snapshot = await tree.promise
  equal(snapshot.from, 10)
  equal([...snapshot.paths], [['/old.txt', 'file']])
  discovery.close()
})

Deno.test('a kept tree chooses the feed cursor and needs no initial crawl', async () => {
  let attempts = 0
  const cursor = result<number | null>()
  const discovery = new TreeDiscovery({
    kept: () =>
      Promise.resolve({ paths: new Map([['/kept.txt', 'file']]), rev: 8 }),
    load: () => {
      attempts++
      return Promise.resolve({ paths: new Map(), rev: 9 })
    },
  }, (tree) => cursor.resolve(tree.from))
  await discovery.restore()
  discovery.opened()
  equal(await cursor.promise, 8)
  equal(attempts, 0)
  discovery.close()
})
