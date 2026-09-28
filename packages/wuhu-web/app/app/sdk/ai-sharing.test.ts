import { aiSharing, aiSharingRefusal, decideAISharing } from '~/lib/ai-sharing'
import { postConversationMessage } from './conversation.ts'
import {
  compactSession,
  createSession,
  restartSession,
  unarchiveSession,
} from './session.ts'
import { transcribe } from './transcribe.ts'

function equal(actual: unknown, expected: unknown) {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

const sent: string[] = []
globalThis.fetch = (input: RequestInfo | URL, init?: RequestInit) => {
  sent.push(`${init?.method ?? 'GET'} ${input}`)
  return Promise.resolve(new Response('{}'))
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

const desk = { id: 'desk', group: 'shared' }

const calls: [string, () => Promise<unknown>][] = [
  ['POST /v1/session', () => createSession({ title: 'Audit' }, 'shared')],
  [
    'POST /v1/conversation/message',
    () => postConversationMessage({ session: 'desk' }, 'shared', 'hello'),
  ],
  [
    'POST /v1/transcribe',
    () => transcribe(new Blob([new Uint8Array(4)], { type: 'audio/webm' })),
  ],
  ['POST /v1/session/desk/compact', () => compactSession(desk, '')],
  [
    'POST /v1/session/desk/restart',
    () => restartSession(desk, { timezone: 'UTC' }),
  ],
  ['POST /v1/session/desk/unarchive', () => unarchiveSession(desk)],
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
