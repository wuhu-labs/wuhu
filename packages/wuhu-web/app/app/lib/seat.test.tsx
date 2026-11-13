import { GlobalRegistrator } from '@happy-dom/global-registrator'
import { assertEquals } from 'jsr:@std/assert@1'
import { act } from 'react'
import { createRoot } from 'react-dom/client'
import type { RetryClock } from './retry-read.ts'
import { Seated } from './seat.tsx'
import { useOwnPrincipal } from './use-directory.tsx'
import { useDrafts } from './use-drafts.tsx'

// A browser without a key, in front of a server whose persona answer the test
// sets; retries wait for the test to fire them.
async function keylessShell(
  persona: { answer: () => Promise<Response> },
  run: (shown: () => string, retry: () => Promise<void>) => Promise<void>,
) {
  GlobalRegistrator.register()
  ;(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean })
    .IS_REACT_ACT_ENVIRONMENT = true
  const request = <T,>(result: T) => {
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
  globalThis.fetch = (input: RequestInfo | URL) => {
    const url = new URL(
      input instanceof Request ? input.url : String(input),
      'https://space.test',
    )
    switch (url.pathname) {
      case '/v1/persona':
        return persona.answer()
      case '/v1/server':
        return Promise.resolve(Response.json({ space: 'spc_dev' }))
      case '/v1/users':
        return Promise.resolve(Response.json({ users: [] }))
      default:
        return Promise.resolve(new Response('', { status: 404 }))
    }
  }
  const retries: (() => void)[] = []
  const clock: RetryClock = {
    after: (_, callback) => {
      retries.push(callback)
      return () => {}
    },
  }
  const settle = () => new Promise((resolve) => setTimeout(resolve, 0))
  function Shown({ scope }: { scope: string | null }) {
    const principal = useOwnPrincipal()
    const drafts = useDrafts()
    return [
      scope ?? 'no scope',
      drafts === null ? 'no drafts' : 'drafts',
      principal === undefined ? 'asking' : principal ?? 'nobody',
    ].join(' · ')
  }
  const host = document.createElement('div')
  const root = createRoot(host)
  try {
    await act(async () => {
      root.render(
        <Seated clock={clock}>{({ scope }) => <Shown scope={scope} />}</Seated>,
      )
      await settle()
    })
    await run(() => host.textContent ?? '', async () => {
      assertEquals(retries.length, 1)
      await act(async () => {
        retries.shift()!()
        await settle()
      })
    })
    assertEquals(retries.length, 0)
  } finally {
    await act(() => root.unmount())
    await GlobalRegistrator.unregister()
  }
}

Deno.test('a failed first ask leaves the shell unseated and a retry seats the dev person everywhere', async () => {
  const persona: { answer: () => Promise<Response> } = {
    answer: () => Promise.reject(new TypeError('network down')),
  }
  await keylessShell(persona, async (shown, retry) => {
    assertEquals(shown(), 'no scope · no drafts · asking')
    persona.answer = () =>
      Promise.resolve(Response.json({ persona: 'frame-dawn-mango' }))
    await retry()
    assertEquals(
      shown(),
      'frame-dawn-mango:spc_dev · drafts · frame-dawn-mango',
    )
  })
})

Deno.test('a refusal seats nobody for good', async () => {
  const persona = {
    answer: () =>
      Promise.resolve(
        Response.json({ code: 'unauthorized' }, { status: 401 }),
      ),
  }
  await keylessShell(persona, (shown) => {
    assertEquals(shown(), 'no scope · no drafts · nobody')
    return Promise.resolve()
  })
})
