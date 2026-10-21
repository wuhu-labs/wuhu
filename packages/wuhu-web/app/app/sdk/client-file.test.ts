import { SpaceServer } from './client.ts'
import type { Entry, ReadOutput } from '~/lib/contract.gen'
import type { Observation } from './observation.ts'

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

function request<T>(result: T) {
  const pending: { result: T; onsuccess?: () => void } = { result }
  queueMicrotask(() => pending.onsuccess?.())
  return pending
}

function files() {
  const originalFetch = globalThis.fetch
  const originalIDB = globalThis.indexedDB
  globalThis.indexedDB = {
    open: () =>
      request({
        transaction: () => ({
          objectStore: () => ({ get: () => request(null) }),
        }),
        close: () => {},
      }),
  } as unknown as IDBFactory
  const cache = new Map<string, unknown>()
  let cacheFails = false
  const caches = {
    of: () => ({
      get: <T>(kind: string, key: string) =>
        cacheFails
          ? Promise.reject(new Error('cache unavailable'))
          : Promise.resolve(cache.get(`${kind}:${key}`) as T | undefined),
      put: (kind: string, key: string, value: unknown) => {
        cache.set(`${kind}:${key}`, value)
        return Promise.resolve()
      },
    }),
  }
  let output: ReadOutput = { content: 'fresh', token: 'one' }
  let nextRead: Promise<ReadOutput> | undefined
  const started = result<void>()
  let unreachable = false
  let onRead = () => {}
  let code: string | undefined
  let status = 200
  const calls: string[] = []
  globalThis.fetch = (input, init) => {
    const url = String(input)
    calls.push(url)
    if (url === '/v1/tools/read' || url === '/v1/tools/stat') {
      equal(JSON.parse(String(init?.body)), { path: '/note.txt' })
      if (url.endsWith('/read')) {
        started.resolve()
        onRead()
        if (unreachable) return Promise.reject(new TypeError('unreachable'))
        if (nextRead !== undefined) {
          const reply = nextRead
          nextRead = undefined
          return reply.then((value) => Response.json(value))
        }
      }
      return Promise.resolve(Response.json(
        status === 200
          ? url.endsWith('/read') ? output : { kind: 'file', name: 'note.txt' }
          : {
            code: code ?? (status === 404 ? 'notFound' : 'internal'),
            message: 'refused',
          },
        { status },
      ))
    }
    if (url === '/v1/tools/write') {
      return Promise.resolve(Response.json({ token: 'written', rev: 12 }))
    }
    if (url === '/v1/tools/sync') {
      return Promise.resolve(
        Response.json({
          kind: 'merged',
          token: 'merged',
          content: 'server merge',
          rev: 13,
        }),
      )
    }
    throw new Error(`a file observation must not open another feed: ${url}`)
  }
  const server = new SpaceServer(caches)
  const client = server.client('shared')
  return {
    server,
    started: started.promise,
    set code(value: string) {
      code = value
    },
    set unreachable(value: boolean) {
      unreachable = value
    },
    set onRead(value: () => void) {
      onRead = value
    },
    set pendingRead(value: Promise<ReadOutput>) {
      nextRead = value
    },
    client,
    cache,
    calls,
    set output(value: ReadOutput) {
      output = value
    },
    set status(value: number) {
      status = value
    },
    rejectCache() {
      cacheFails = true
    },
    touch(path = '/note.txt') {
      client.filesChanged({
        rev: 11,
        events: [{ kind: 'write', path, entry: 'file', rev: 11 }],
      })
    },
    close() {
      globalThis.fetch = originalFetch
      globalThis.indexedDB = originalIDB
    },
  }
}

function values<T>(observation: Observation<T>) {
  const queue = [result<T>(), result<T>(), result<T>()]
  const failure = result<unknown>()
  let index = 0
  const stop = observation(
    (value) => queue[index++]!.resolve(value),
    failure.resolve,
  )
  return { queue, failure: failure.promise, stop }
}

Deno.test('read paints kept, fetches once, and follows the existing group feed', async () => {
  const fake = files()
  fake.cache.set('document:/note.txt', { content: 'kept', token: 'old' })
  const read = values(fake.client.read('/note.txt'))
  try {
    equal(await read.queue[0]!.promise, { content: 'kept', token: 'old' })
    equal(await read.queue[1]!.promise, { content: 'fresh', token: 'one' })
    fake.client.filesConnected()
    equal(fake.calls, ['/v1/tools/read'])
    fake.output = { content: 'remote edit', token: 'two' }
    fake.touch()
    equal(await read.queue[2]!.promise, {
      content: 'remote edit',
      token: 'two',
    })
    equal(fake.cache.get('document:/note.txt'), {
      content: 'remote edit',
      token: 'two',
    })
    read.stop()
    fake.touch()
    equal(fake.calls, ['/v1/tools/read', '/v1/tools/read'])
  } finally {
    read.stop()
    fake.close()
  }
})

Deno.test('ordinary reconnect preserves successful read/stat snapshots', async () => {
  const fake = files()
  const read = values(fake.client.read('/note.txt'))
  const stat = values<Entry>(fake.client.stat('/note.txt'))
  try {
    await read.queue[0]!.promise
    await stat.queue[0]!.promise
    fake.client.filesConnected()
    equal(fake.calls.filter((url) => url.endsWith('/read')).length, 1)
    equal(fake.calls.filter((url) => url.endsWith('/stat')).length, 1)
    fake.client.filesConnected()
    equal(fake.calls.filter((url) => url.endsWith('/read')).length, 1)
    equal(fake.calls.filter((url) => url.endsWith('/stat')).length, 1)
  } finally {
    read.stop()
    stat.stop()
    fake.close()
  }
})

Deno.test('cache refusal does not block a live read; transient failure retries on the next group snapshot', async () => {
  const fake = files()
  fake.rejectCache()
  fake.unreachable = true
  const read = values(fake.client.read('/note.txt'))
  try {
    await read.failure
    fake.unreachable = false
    fake.touch('/unrelated.txt')
    equal(await read.queue[0]!.promise, { content: 'fresh', token: 'one' })
  } finally {
    read.stop()
    fake.close()
  }
})

Deno.test('a refusal after kept paint recovers when the group feed touches the file', async () => {
  const fake = files()
  fake.cache.set('document:/note.txt', { content: 'kept', token: 'old' })
  fake.status = 404
  const read = values(fake.client.read('/note.txt'))
  try {
    await read.queue[0]!.promise
    await read.failure
    fake.status = 200
    fake.touch()
    equal(await read.queue[1]!.promise, { content: 'fresh', token: 'one' })
  } finally {
    read.stop()
    fake.close()
  }
})

Deno.test('acknowledged writes and merged sync content are kept for the next open', async () => {
  const fake = files()
  let reopened: ReturnType<typeof values<ReadOutput>> | undefined
  try {
    await fake.client.write('/note.txt', 'submitted')
    equal(fake.cache.get('document:/note.txt'), {
      token: 'written',
      content: 'submitted',
    })
    await fake.client.sync('/note.txt', 'written', 'local edit')
    equal(fake.cache.get('document:/note.txt'), {
      token: 'merged',
      content: 'server merge',
    })
    reopened = values(fake.server.client('shared').read('/note.txt'))
    equal(await reopened.queue[0]!.promise, {
      token: 'merged',
      content: 'server merge',
    })
    await reopened.queue[1]!.promise
  } finally {
    reopened?.stop()
    fake.close()
  }
})

Deno.test('matching touches coalesce while the initial file read is in flight', async () => {
  const fake = files()
  const first = result<ReadOutput>()
  fake.pendingRead = first.promise
  const read = values(fake.client.read('/note.txt'))
  try {
    await fake.started
    fake.touch()
    fake.touch()
    first.resolve({ content: 'initial', token: 'initial' })
    await read.queue[0]!.promise
    equal(await read.queue[1]!.promise, { content: 'fresh', token: 'one' })
    equal(fake.calls, ['/v1/tools/read', '/v1/tools/read'])
  } finally {
    read.stop()
    fake.close()
  }
})

Deno.test('unsupported and other server refusals park until the file changes', async () => {
  const fake = files()
  fake.status = 415
  fake.code = 'unsupported'
  const read = values(fake.client.read('/note.txt'))
  try {
    await read.failure
    fake.touch('/unrelated.txt')
    fake.client.filesConnected()
    equal(fake.calls, ['/v1/tools/read'])
    fake.status = 200
    fake.touch()
    equal(await read.queue[0]!.promise, { content: 'fresh', token: 'one' })
  } finally {
    read.stop()
    fake.close()
  }
})

Deno.test('an equal refreshed value is not emitted again', async () => {
  const fake = files()
  const equalRead = result<ReadOutput>()
  const started = result<void>()
  const read = values(fake.client.read('/note.txt'))
  try {
    await read.queue[0]!.promise
    fake.pendingRead = equalRead.promise
    fake.onRead = started.resolve
    fake.touch()
    await started.promise
    fake.output = { content: 'changed', token: 'two' }
    fake.touch()
    equalRead.resolve({ content: 'fresh', token: 'one' })
    equal(await read.queue[1]!.promise, { content: 'changed', token: 'two' })
  } finally {
    read.stop()
    fake.close()
  }
})

for (
  const code of [
    'internal',
    'unavailable',
    'unauthorized',
    'provider_auth',
    'provider_unavailable',
  ]
) {
  Deno.test(`${code} is a service failure and retries on the next snapshot`, async () => {
    const fake = files()
    fake.status = 503
    fake.code = code
    const read = values(fake.client.read('/note.txt'))
    try {
      await read.failure
      fake.status = 200
      fake.touch('/unrelated.txt')
      equal(await read.queue[0]!.promise, { content: 'fresh', token: 'one' })
    } finally {
      read.stop()
      fake.close()
    }
  })
}

Deno.test('an equal stat value clears a previously delivered refusal', async () => {
  const fake = files()
  const stat = values(fake.client.stat('/note.txt'))
  try {
    const original = await stat.queue[0]!.promise
    fake.status = 404
    fake.touch()
    await stat.failure
    fake.status = 200
    fake.touch()
    equal(await stat.queue[1]!.promise, original)
  } finally {
    stat.stop()
    fake.close()
  }
})

Deno.test('reconnect retries an unreachable read without a separate stream', async () => {
  const fake = files()
  fake.unreachable = true
  const read = values(fake.client.read('/note.txt'))
  try {
    await read.failure
    fake.unreachable = false
    fake.client.filesConnected()
    equal(await read.queue[0]!.promise, { content: 'fresh', token: 'one' })
    equal(fake.calls, ['/v1/tools/read', '/v1/tools/read'])
  } finally {
    read.stop()
    fake.close()
  }
})
