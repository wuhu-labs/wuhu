import { assertEquals } from 'jsr:@std/assert@1'
import { onUnauthorized } from './http.ts'
import { ownViewer } from './viewer.ts'

// A browser without a key: the device store opens and holds none.
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

function serving(persona: Response): Request[] {
  const asked: Request[] = []
  globalThis.fetch = (input: RequestInfo | URL, init?: RequestInit) => {
    const sent = new Request(new URL(String(input), 'https://space.test'), init)
    asked.push(sent)
    if (sent.url.endsWith('/v1/server')) {
      return Promise.resolve(Response.json({ space: 'spc_dev' }))
    }
    return Promise.resolve(persona.clone())
  }
  return asked
}

Deno.test('without a key, a server that seats unsigned requests names the viewer', async () => {
  const asked = serving(Response.json({ persona: 'frame-dawn-mango' }))
  assertEquals(await ownViewer(), {
    principal: 'frame-dawn-mango',
    spaceId: 'spc_dev',
  })
  assertEquals(asked[0].method, 'POST')
  assertEquals(new URL(asked[0].url).pathname, '/v1/persona')
  assertEquals(asked[0].headers.get('authorization'), null)
})

Deno.test('without a key, a server that refuses unsigned requests seats nobody and signs nobody out', async () => {
  let signedOut = false
  onUnauthorized(() => signedOut = true)
  try {
    const asked = serving(
      Response.json({
        code: 'unauthorized',
        message: 'a bearer assertion is required',
      }, { status: 401 }),
    )
    assertEquals(await ownViewer(), null)
    assertEquals(asked.length, 1)
    assertEquals(signedOut, false)
  } finally {
    onUnauthorized(null)
  }
})
