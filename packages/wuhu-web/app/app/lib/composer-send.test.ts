import { decideAISharing } from './ai-sharing.ts'
import type { EntryKind } from './contract.gen.ts'
import { composerSend } from './composer-send.ts'
import { loadShownNode, type NodeSource, type NodeView } from './node-view.ts'
import { viewingOf } from './viewing.ts'
import { ApiError } from '../sdk/errors.ts'

function equal(actual: unknown, expected: unknown) {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

// An unenrolled browser: the device store opens and holds no key.
function request<T>(result: T) {
  const pending: { result: T; onsuccess?: () => void } = { result }
  queueMicrotask(() => pending.onsuccess?.())
  return pending
}
const unenrolled = {
  open: () =>
    request({
      transaction: () => ({
        objectStore: () => ({ get: () => request(null) }),
      }),
      close: () => {},
    }),
} as unknown as IDBFactory

// Records every request at the fetch boundary, answering each with the next
// response in line, then `{}`.
async function recording(
  responses: Response[],
  run: () => Promise<void>,
): Promise<{ group: string | null; body: Record<string, unknown> }[]> {
  const fetch = globalThis.fetch
  const indexedDB = globalThis.indexedDB
  const sent: { group: string | null; body: Record<string, unknown> }[] = []
  globalThis.fetch = (_input: RequestInfo | URL, init?: RequestInit) => {
    sent.push({
      group: new Headers(init?.headers).get('wuhu-group'),
      body: JSON.parse(String(init?.body)),
    })
    return Promise.resolve(responses.shift() ?? new Response('{}'))
  }
  globalThis.indexedDB = unenrolled
  localStorage.clear()
  decideAISharing('allowed')
  try {
    await run()
  } finally {
    globalThis.fetch = fetch
    globalThis.indexedDB = indexedDB
    localStorage.clear()
  }
  return sent
}

const origin = 'https://shared.space.test'

function space(files: Record<string, string>): NodeSource {
  return {
    stat: (path) => {
      const kind: EntryKind | undefined = path === '/'
        ? 'directory'
        : path in files
        ? 'file'
        : undefined
      return kind === undefined
        ? Promise.reject(
          new ApiError(404, { code: 'notFound', message: `${path} missing` }),
        )
        : Promise.resolve({ kind })
    },
    read: (path) => Promise.resolve({ content: files[path], token: 't1' }),
  }
}

// What the docked composer sends, from the node page as the root route holds
// it (lib/use-shown-node.ts) to the moment Send posts.
async function sendFrom(files: Record<string, string>, requested: string) {
  const shown = await loadShownNode(space(files), origin, requested, '')
  await composerSend({
    target: { kind: 'session', id: 'desk' },
    group: 'team',
    viewing: viewingOf({ group: 'shared', requested, ...shown }),
  })('look')
}

const post = (extra: Record<string, string>) => ({
  group: 'team',
  body: {
    session: 'desk',
    message: 'look',
    timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    ...extra,
  },
})

Deno.test('Send names the page the node page shows', async () => {
  const sent = await recording([], async () => {
    await sendFrom({ '/notes/plan.md': '# Plan' }, '/notes/plan.md')
    // The root resolves to its homepage; its own listing names no page.
    await sendFrom({ '/index.md': '# Home' }, '/')
    await sendFrom({}, '/')
  })
  equal(sent, [
    post({ viewing: 'wuhu://shared.localspace/notes/plan.md' }),
    post({ viewing: 'wuhu://shared.localspace/index.md' }),
    post({}),
  ])
})

Deno.test('a page loading or failed is not on screen', () => {
  const shown = (view: NodeView) =>
    viewingOf({
      group: 'shared',
      requested: '/plan.md',
      path: '/plan.md',
      view,
    })
  equal(shown({ state: 'loading' }), null)
  equal(shown({ state: 'error', message: 'gone' }), null)
  equal(
    shown({ state: 'text', content: '' }),
    'wuhu://shared.localspace/plan.md',
  )
  equal(viewingOf(null), null)
})

const refusal = (reason: string) =>
  new Response(
    JSON.stringify({
      code: 'invalidArgument',
      message:
        'viewing wuhu://shared.localspace/gone.md is not a path you can read',
      reason,
    }),
    { status: 400 },
  )

Deno.test('a refused viewing is sent again without it, once', async () => {
  const logged: unknown[][] = []
  const warn = console.warn
  console.warn = (...line: unknown[]) => logged.push(line)
  const sent = await recording(
    [refusal('viewing')],
    () => sendFrom({ '/gone.md': '# Gone' }, '/gone.md'),
  ).finally(() => console.warn = warn)
  equal(sent, [
    post({ viewing: 'wuhu://shared.localspace/gone.md' }),
    post({}),
  ])
  // The server's message names the path; the log carries neither.
  equal(logged, [[
    'The server refused viewing (reason viewing); sending without it',
  ]])
})

Deno.test('a page refused again is not dropped twice', async () => {
  let failure: unknown
  const sent = await recording(
    [refusal('viewing'), refusal('viewing'), refusal('viewing')],
    () =>
      sendFrom({ '/gone.md': '# Gone' }, '/gone.md').catch((caught) => {
        failure = caught
      }),
  )
  equal(sent, [
    post({ viewing: 'wuhu://shared.localspace/gone.md' }),
    post({}),
  ])
  equal((failure as ApiError).detail.reason, 'viewing')
})

Deno.test('any other refusal reaches the composer', async () => {
  let failure: unknown
  const sent = await recording(
    [refusal('other'), refusal('viewing')],
    async () => {
      await sendFrom({ '/a.md': '' }, '/a.md').catch((caught) => {
        failure = caught
      })
      await sendFrom({}, '/').catch((caught) => {
        failure = [failure, caught]
      })
    },
  )
  equal(sent, [post({ viewing: 'wuhu://shared.localspace/a.md' }), post({})])
  const [other, without] = failure as ApiError[]
  equal([other.detail.reason, without.detail.reason], ['other', 'viewing'])
})
