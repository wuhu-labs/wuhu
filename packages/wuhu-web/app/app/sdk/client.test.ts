import { SpaceServer } from './client.ts'

function equal(actual: unknown, expected: unknown) {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

// The API origin answers; the content origin is reachable or not.
let reachable = true
let mintStatus = 204
const mints: string[] = []
globalThis.fetch = (input: RequestInfo | URL, init?: RequestInit) => {
  const url = String(input)
  if (url === '/v1/server') {
    return Promise.resolve(
      Response.json({ webOrigin: 'https://space.test:5791' }),
    )
  }
  mints.push(`${init?.method} ${url}`)
  if (!reachable) return Promise.reject(new TypeError('Failed to fetch'))
  return Promise.resolve(new Response(null, { status: mintStatus }))
}

// An unenrolled browser: the device store opens and holds no key.
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
      close: () => {},
    }),
} as unknown as IDBFactory

const origin = 'https://space.test:5791'

Deno.test('online but out of reach, the content origin still paints and mints again later', async () => {
  const client = new SpaceServer().client('shared')
  reachable = false
  mintStatus = 204
  mints.length = 0
  equal(globalThis.navigator?.onLine !== false, true)

  equal(await client.contentOrigin(), origin)
  // Nothing was remembered, so the next ask mints again.
  equal(await client.contentOrigin(), origin)
  equal(mints.length, 2)

  reachable = true
  equal(await client.remintContentSession(), origin)
  equal(await client.contentOrigin(), origin)
  equal(mints, [
    `POST ${origin}/_/session`,
    `POST ${origin}/_/session`,
    `POST ${origin}/_/session`,
  ])
})

Deno.test('a refused mint throws and is not remembered', async () => {
  const client = new SpaceServer().client('shared')
  reachable = true
  mintStatus = 403
  mints.length = 0

  const refused = await client.contentOrigin().then(
    () => 'painted',
    (failure: Error) => failure.message,
  )
  equal(refused, 'content session bootstrap failed: HTTP 403')

  mintStatus = 204
  equal(await client.contentOrigin(), origin)
  equal(mints.length, 2)
})
