import { GlobalRegistrator } from '@happy-dom/global-registrator'
import { assertEquals, assertStringIncludes } from 'jsr:@std/assert@1'
import { act } from 'react'
import { createRoot } from 'react-dom/client'
import { MemoryRouter } from 'react-router'
import type { SessionRecord } from './session-model.ts'

Deno.test('SessionMenu archive refuses busy work before a separately chosen force request', async () => {
  GlobalRegistrator.register()
  ;(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean })
    .IS_REACT_ACT_ENVIRONMENT = true
  const { SessionMenu } = await import('~/components/session-menu')
  const record: SessionRecord = {
    id: 'desk',
    group: 'shared',
    title: 'Audit',
    kind: 'agent',
    lifecycle: 'live',
    parent: null,
    createdBy: 'owner',
    createdAt: '',
    lastActivityAt: '',
    errorMessage: null,
    unread: 0,
    executorLabel: 'proof/scripted',
    spec: {},
    hold: '',
    work: '',
    runState: 'inference',
  }
  const bodies: unknown[] = []
  const originalFetch = globalThis.fetch
  globalThis.fetch = (_input, init) => {
    bodies.push(JSON.parse(String(init?.body)))
    return Promise.resolve(
      new Response(
        bodies.length === 1
          ? JSON.stringify({
            code: 'conflict',
            message: 'busy: desk (Audit), child (Research)',
          })
          : '{}',
        { status: bodies.length === 1 ? 409 : 200 },
      ),
    )
  }
  const pending = <T,>(result: T) => {
    const request: { result: T; onsuccess?: () => void } = { result }
    queueMicrotask(() => request.onsuccess?.())
    return request
  }
  globalThis.indexedDB = {
    open: () =>
      pending({
        transaction: () => ({
          objectStore: () => ({ get: () => pending(null) }),
        }),
        close() {},
      }),
  } as unknown as IDBFactory
  const host = document.createElement('div')
  document.body.append(host)
  const root = createRoot(host)
  const click = async (element: HTMLElement) => {
    await act(() => element.click())
  }
  try {
    await act(() =>
      root.render(
        <MemoryRouter>
          <SessionMenu record={record} />
        </MemoryRouter>,
      )
    )
    await click(host.querySelector('button')!)
    const transcript = [
      ...document.querySelectorAll<HTMLElement>('[role=menuitem]'),
    ].find((item) => item.textContent === 'Transcript')!
    assertEquals(transcript.getAttribute('role'), 'menuitem')
    assertEquals(transcript.hasAttribute('aria-checked'), false)
    const archive = [
      ...document.querySelectorAll<HTMLElement>('[role=menuitem]'),
    ].find((item) => item.textContent === 'Archive')!
    await click(archive)
    const dialog = host.querySelector('dialog[open]')!
    const confirmation = () =>
      [...dialog.querySelectorAll<HTMLButtonElement>('button')].find((button) =>
        button.textContent !== 'Cancel'
      )!
    await click(confirmation())
    assertEquals(bodies, [{ force: false }])
    assertStringIncludes(dialog.textContent!, 'desk (Audit), child (Research)')
    assertEquals(confirmation().textContent, 'Stop work and archive')
    await click(confirmation())
    assertEquals(bodies, [{ force: false }, { force: true }])
  } finally {
    await act(() => root.unmount())
    host.remove()
    globalThis.fetch = originalFetch
    await GlobalRegistrator.unregister()
  }
})
