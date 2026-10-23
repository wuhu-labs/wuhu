import { aiSharing, aiSharingRefusal, decideAISharing } from '~/lib/ai-sharing'
import { postConversationMessage } from './conversation.ts'
import { archiveSession, createSession, restartSession } from './session.ts'
import { ApiError } from './errors.ts'
import { transcribe } from './transcribe.ts'

function equal(actual: unknown, expected: unknown) {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

let responseStatus = 200
const sent: string[] = []
const effects: { url: string; body: unknown; group: string | undefined }[] = []
globalThis.fetch = (input: RequestInfo | URL, init?: RequestInit) => {
  sent.push(`${init?.method ?? 'GET'} ${input}`)
  effects.push({
    url: String(input),
    body: typeof init?.body === 'string' ? JSON.parse(init.body) : null,
    group: (init?.headers as Record<string, string>)?.['wuhu-group'],
  })
  return Promise.resolve(
    new Response(
      responseStatus === 409
        ? JSON.stringify({
          code: 'conflict',
          message: 'Busy sessions: desk (Audit), child (Research)',
        })
        : '{}',
      { status: responseStatus },
    ),
  )
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

const calls: [string, () => Promise<unknown>][] = [
  [
    'POST /v1/session/desk/restart',
    () =>
      restartSession({ id: 'desk', group: 'shared' }, {
        message: 'hello',
        timezone: 'UTC',
      }),
  ],
  ['POST /v1/session', () => createSession({ title: 'Audit' }, 'shared')],
  [
    'POST /v1/conversation/message',
    () => postConversationMessage({ session: 'desk' }, 'shared', 'hello'),
  ],
  [
    'POST /v1/transcribe',
    () => transcribe(new Blob([new Uint8Array(4)], { type: 'audio/webm' })),
  ],
]

async function refusals(): Promise<string[]> {
  const reasons: string[] = []
  for (const [, call] of calls) {
    await call().then(
      () => reasons.push('sent'),
      (failure: Error) => reasons.push(failure.message),
    )
  }
  return reasons
}

Deno.test('undecided or declined, every AI call refuses and sends nothing', async () => {
  localStorage.clear()
  sent.length = 0
  equal(aiSharing(), null)
  equal(await refusals(), calls.map(() => aiSharingRefusal))
  decideAISharing('declined')
  equal(await refusals(), calls.map(() => aiSharingRefusal))
  equal(sent, [])
})

Deno.test('allowed, every AI call goes out; withdrawn, they stop again', async () => {
  localStorage.clear()
  sent.length = 0
  decideAISharing('allowed')
  equal(await refusals(), calls.map(() => 'sent'))
  equal(sent, calls.map(([request]) => request))
  decideAISharing('declined')
  equal(await refusals(), calls.map(() => aiSharingRefusal))
  equal(sent.length, calls.length)
  localStorage.clear()
})

Deno.test('session actions emit scoped request bodies; archive needs no AI consent', async () => {
  localStorage.clear()
  effects.length = 0
  const address = { id: 'desk', group: 'private' }
  await archiveSession(address)
  await archiveSession(address, { force: false })
  await archiveSession(address, { force: true })
  decideAISharing('allowed')
  const direct = {
    provider: 'codex',
    model: 'sol',
    effort: 'high',
    message: 'Hello',
    timezone: 'UTC',
  }
  const group = {
    modelGroup: 'writers',
    effort: 'medium',
    timezone: 'Asia/Shanghai',
  }
  await restartSession(address, direct)
  await restartSession(address, group)
  equal(effects, [
    { url: '/v1/session/desk/archive', body: {}, group: 'private' },
    {
      url: '/v1/session/desk/archive',
      body: { force: false },
      group: 'private',
    },
    {
      url: '/v1/session/desk/archive',
      body: { force: true },
      group: 'private',
    },
    { url: '/v1/session/desk/restart', body: direct, group: 'private' },
    { url: '/v1/session/desk/restart', body: group, group: 'private' },
  ])
  localStorage.clear()
})

Deno.test('a busy archive preserves the server conflict and never retries force automatically', async () => {
  effects.length = 0
  responseStatus = 409
  try {
    await archiveSession({ id: 'desk', group: 'shared' }).then(
      () => {
        throw new Error('expected conflict')
      },
      (failure: unknown) => {
        if (!(failure instanceof ApiError)) throw failure
        equal(failure.status, 409)
        equal(failure.message, 'Busy sessions: desk (Audit), child (Research)')
      },
    )
    equal(effects, [{
      url: '/v1/session/desk/archive',
      body: {},
      group: 'shared',
    }])
  } finally {
    responseStatus = 200
  }
})
