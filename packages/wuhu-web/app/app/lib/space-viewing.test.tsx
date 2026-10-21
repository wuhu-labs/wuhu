/// <reference lib="deno.ns" />
import { GlobalRegistrator } from '@happy-dom/global-registrator'
import type { SpaceFeeds } from './space-feeds.tsx'
import type { SessionRecord } from './session-model.ts'
import type { SpaceServer } from '~/sdk/client'
import type { SpaceContext } from '../routes/space.tsx'

function equal(actual: unknown, expected: unknown) {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

// An IndexedDB that holds nothing: no device key, no draft files.
function request<T>(result: T) {
  const pending: {
    result: T
    onsuccess?: (event: { target: unknown }) => void
  } = { result }
  queueMicrotask(() => pending.onsuccess?.({ target: pending }))
  return pending
}
const emptyStore = {
  get: () => request(undefined),
  put: () => request(undefined),
  delete: () => request(undefined),
  openKeyCursor: () => request(null),
}
const emptyDatabase = {
  createObjectStore: () => emptyStore,
  close: () => {},
  transaction: () => {
    const transaction: { objectStore: () => unknown; oncomplete?: () => void } =
      { objectStore: () => emptyStore }
    setTimeout(() => transaction.oncomplete?.())
    return transaction
  },
}
const emptyIndexedDB = { open: () => request(emptyDatabase) }

const agent: SessionRecord = {
  id: 'agent',
  group: 'shared',
  title: 'Desk',
  hold: 'none',
  work: 'idle',
  runState: 'no_run',
  lifecycle: 'active',
  kind: 'agent',
  parent: null,
  unread: false,
  executorLabel: 'kernel',
  spec: {},
  lastActivityAt: '2026-10-16T00:00:00Z',
  errorMessage: null,
  createdBy: 'person',
}

// The real space layout and node route over a fake server, from a send's
// point of view: what the composer posts as `viewing` while the reader moves
// between an agent's box, a page, a page the feed's tree
// does not list yet, a page still loading and a screen.
Deno.test({
  name: 'Send names the page the node route has on screen, and nothing else',
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    // Deno's test runner reports through the global event target, so the
    // window keeps Deno's own.
    const { addEventListener, removeEventListener, dispatchEvent } = globalThis
    GlobalRegistrator.register({
      url: 'https://space.test/',
      settings: { disableIframePageLoading: true },
    })
    Object.assign(globalThis, {
      addEventListener,
      removeEventListener,
      dispatchEvent,
      indexedDB: emptyIndexedDB,
      matchMedia: (media: string) => ({
        matches: false,
        media,
        addEventListener: () => {},
        removeEventListener: () => {},
        addListener: () => {},
        removeListener: () => {},
      }),
    })
    ;(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean })
      .IS_REACT_ACT_ENVIRONMENT = true
    // Only a send answers; every other request stays pending.
    const sent: Record<string, unknown>[] = []
    globalThis.fetch = (input: RequestInfo | URL, init?: RequestInit) => {
      if (String(input).endsWith('/v1/conversation/message')) {
        const { message, viewing } = JSON.parse(String(init?.body))
        sent.push(viewing === undefined ? { message } : { message, viewing })
        return Promise.resolve(
          new Response(JSON.stringify({ messageId: 'm', n: 1 })),
        )
      }
      return new Promise<Response>(() => {})
    }
    try {
      const { act } = await import('react')
      const { createRoot } = await import('react-dom/client')
      const { createMemoryRouter, RouterProvider, useOutletContext } =
        await import('react-router')
      const { decideAISharing } = await import('./ai-sharing.ts')
      const { SpaceFeedsContext } = await import('./space-feeds.tsx')
      const { DraftsProvider } = await import('./use-drafts.tsx')
      const { SpaceBody } = await import('../routes/space.tsx')
      decideAISharing('allowed')

      const stats: string[] = []
      // `/deep/b.txt` is a deep link the feed's crawl has not reached: on
      // screen, so named, though the tree does not list it.
      const files: Record<string, string> = {
        '/notes/a.txt': 'A',
        '/deep/b.txt': 'B',
      }
      const client = {
        group: 'shared',
        stat: (path: string) =>
        (
          receive: (value: { kind: string }) => void,
          failure: (error: Error) => void,
        ) => {
          stats.push(path)
          if (path !== '/slow.txt') {
            queueMicrotask(() => {
              if (path in files) receive({ kind: 'file' })
              else failure(new Error(`${path} missing`))
            })
          }
          return () => {}
        },
        read:
          (path: string) =>
          (receive: (value: { content: string; token: string }) => void) => {
            queueMicrotask(() =>
              receive({ content: files[path]!, token: 't1' })
            )
            return () => {}
          },
        remintContentSession: () => Promise.resolve(null),
      }
      const server = {
        info: () => new Promise(() => {}),
        client: () => client,
      } as unknown as SpaceServer
      const feed = {
        loaded: true,
        error: null,
        files: {
          paths: new Map([['/notes', 'directory'], ['/notes/a.txt', 'file']]),
          rev: 1,
          themeRev: 0,
          avatarRevs: {},
        },
        sidebars: [],
        liveness: 'live',
        sessions: [agent],
        channels: [],
        contentOrigin: 'https://shared.space.test',
      } as const
      const feeds: SpaceFeeds = {
        groups: [{ id: 'shared', member: true }] as SpaceFeeds['groups'],
        feed: () => feed as unknown as ReturnType<SpaceFeeds['feed']>,
        liveness: 'live',
        sessions: [agent],
      }

      // node.tsx pulls in the editor's CSS, which Deno cannot import; this
      // renders the outlet's `shown` the way its NodePage does, and nothing
      // else.
      const Node = () => {
        const { shown } = useOutletContext<SpaceContext>()
        const view = shown?.view ?? { state: 'loading' }
        return (
          <div className='wuhu-page'>
            {view.state === 'text'
              ? <pre className='wuhu-text'>{view.content}</pre>
              : view.state === 'loading'
              ? 'Loading…'
              : view.state}
          </div>
        )
      }
      const router = createMemoryRouter([{
        path: '/',
        element: (
          <SpaceFeedsContext value={feeds}>
            <DraftsProvider scope='person:space'>
              <SpaceBody server={server} device={null} scope='person:space' />
            </DraftsProvider>
          </SpaceFeedsContext>
        ),
        // The node route's ids as space-routes.ts gives them.
        children: [
          { index: true, id: 'routes/home', element: <Node /> },
          { path: '_/settings', element: <p>Settings</p> },
          { path: '_/sessions/:id', element: <p>Box</p> },
          { path: '*', id: 'routes/node', element: <Node /> },
        ],
      }], { initialEntries: ['/_/sessions/agent'] })
      const container = document.createElement('div')
      document.body.append(container)
      const root = createRoot(container)
      await act(() => {
        root.render(<RouterProvider router={router} />)
      })

      const settle = async (until: () => boolean) => {
        for (let tries = 0; tries < 50 && !until(); tries += 1) {
          await act(() => new Promise((resolve) => setTimeout(resolve, 10)))
        }
        if (!until()) {
          throw new Error(`never settled: ${document.body.innerHTML}`)
        }
      }
      const go = async (to: string, shows: () => boolean) => {
        await act(() => router.navigate(to))
        await settle(shows)
      }
      const send = async (message: string) => {
        const field = document.querySelector('textarea')!
        Object.getOwnPropertyDescriptor(
          HTMLTextAreaElement.prototype,
          'value',
        )!.set!.call(field, message)
        await act(() => {
          field.dispatchEvent(new Event('input', { bubbles: true }))
        })
        const before = sent.length
        await act(() => {
          document.querySelector<HTMLButtonElement>(
            'button[aria-label^="Send"]',
          )!.click()
        })
        await settle(() => sent.length > before)
      }
      const text = () => document.querySelector('pre.wuhu-text')?.textContent

      await settle(() => document.querySelector('textarea') !== null)
      await send('in the box')
      await go('/notes/a.txt', () => text() === 'A')
      await send('on a page')
      await go(
        '/slow.txt',
        () => document.querySelector('.wuhu-page')?.textContent === 'Loading…',
      )
      await send('while it loads')
      await go(
        '/_/settings',
        () => document.body.textContent!.includes('Settings'),
      )
      await send('on a screen')
      await go('/notes/a.txt', () => text() === 'A')
      await send('back on the page')
      await go('/deep/b.txt', () => text() === 'B')
      await send('on a page the tree lacks')

      equal(sent, [
        { message: 'in the box' },
        {
          message: 'on a page',
          viewing: 'wuhu://shared.localspace/notes/a.txt',
        },
        { message: 'while it loads' },
        { message: 'on a screen' },
        {
          message: 'back on the page',
          viewing: 'wuhu://shared.localspace/notes/a.txt',
        },
        {
          message: 'on a page the tree lacks',
          viewing: 'wuhu://shared.localspace/deep/b.txt',
        },
      ])
      // A screen is not a page: nothing loads it.
      equal(stats.includes('/_/settings'), false)
      await act(() => root.unmount())
    } finally {
      await GlobalRegistrator.unregister()
    }
  },
})
