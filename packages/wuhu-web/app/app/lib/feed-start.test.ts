import { type FeedStart, FeedStartDiscovery } from './feed-start.ts'

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

Deno.test('an unreachable cold start recovers on feed open with the head revision as its cursor', async () => {
  const loaded = result<FeedStart>()
  let attempts = 0
  const discovery = new FeedStartDiscovery({
    kept: () => Promise.reject(new Error('cache unavailable')),
    load: () =>
      ++attempts === 1
        ? Promise.reject(new TypeError('server unreachable'))
        : Promise.resolve(12),
  }, (start) => {
    if (start.from !== null) loaded.resolve(start)
  })
  await discovery.restore()
  discovery.opened()
  equal(await loaded.promise, { from: 12, error: null })
  equal(attempts, 2)
  discovery.close()
})

Deno.test('the head revision is the cursor of a cold start', async () => {
  const start = result<FeedStart>()
  const discovery = new FeedStartDiscovery({
    kept: () => Promise.resolve(undefined),
    load: () => Promise.resolve(10),
  }, start.resolve)
  await discovery.restore()
  equal(await start.promise, { from: 10, error: null })
  discovery.close()
})

Deno.test('a kept revision is the cursor and needs no request', async () => {
  let attempts = 0
  const cursor = result<number | null>()
  const discovery = new FeedStartDiscovery({
    kept: () => Promise.resolve(8),
    load: () => {
      attempts++
      return Promise.resolve(9)
    },
  }, (start) => cursor.resolve(start.from))
  await discovery.restore()
  discovery.opened()
  equal(await cursor.promise, 8)
  equal(attempts, 0)
  discovery.close()
})
