import { assertEquals } from 'jsr:@std/assert@1'
import {
  kindTag,
  type Names,
  sendTarget,
  turnStatus,
  wakeLabel,
  wakeTime,
} from './turn-labels.ts'
import type { SendTarget, Wake, WakeSource } from './turns.ts'

const at = new Date(Date.UTC(2001, 0, 1))

const names: Names = {
  session: (id) => id === 'spoon' ? 'Product Researcher' : undefined,
  principal: (id) => id,
}

function wake(source: WakeSource): Wake {
  return {
    id: { kind: 'kernel', generation: 0, position: 0, part: 0 },
    timestamp: at,
    source,
  }
}

function message(
  { kind = 'message', sender = 'morgan', session = null }: {
    kind?: string
    sender?: string
    session?: string | null
  } = {},
): Wake {
  return wake({
    kind: 'input',
    input: {
      sender,
      text: 'hi',
      conversation: null,
      messageID: null,
      replyTarget: null,
      attachments: [],
      kind,
      senderSession: session,
    },
  })
}

function notice(kind: string): Wake {
  return wake({ kind: 'notice', notice: { kind, text: '', conversations: [] } })
}

Deno.test('a message is labelled with its sender', () => {
  assertEquals(wakeLabel(message(), names), {
    tag: null,
    tone: 'system',
    name: 'morgan',
    timestamp: at,
  })
  assertEquals(wakeLabel(message({ sender: '' }), names).name, 'Input')
})

Deno.test('a sending session is named by its identity', () => {
  const known = message({ sender: 'spoon', session: 'spoon' })
  assertEquals(wakeLabel(known, names).name, 'Product Researcher')
  const unknown = message({ sender: 'lamp', session: 'lamp' })
  assertEquals(wakeLabel(unknown, names).name, 'lamp')
})

Deno.test('reports and requests carry a tag', () => {
  assertEquals(
    wakeLabel(message({ kind: 'progress', session: 'spoon' }), names),
    {
      tag: 'Report · progress',
      tone: 'report',
      name: 'Product Researcher',
      timestamp: at,
    },
  )
  assertEquals(wakeLabel(message({ kind: 'final' }), names), {
    tag: 'Report · final',
    tone: 'report',
    name: 'morgan',
    timestamp: at,
  })
  assertEquals(wakeLabel(message({ kind: 'request' }), names), {
    tag: 'Request',
    tone: 'request',
    name: 'morgan',
    timestamp: at,
  })
})

Deno.test('a notification is tagged by its kind and has no name', () => {
  assertEquals(wakeLabel(notice('timer'), names), {
    tag: 'Timer',
    tone: 'system',
    name: null,
    timestamp: at,
  })
  assertEquals(wakeLabel(notice('restart'), names).tag, 'Started over')
  assertEquals(wakeLabel(notice(''), names).tag, 'Notification')
  assertEquals(wakeLabel(notice('handoff'), names).tag, 'Handoff')
})

Deno.test('each send names where it went', () => {
  const target = (to: SendTarget) => sendTarget({ target: to, text: '' }, names)
  assertEquals(target({ kind: 'box' }), '→ box')
  assertEquals(
    target({ kind: 'session', id: 'spoon' }),
    '→ DM Product Researcher',
  )
  assertEquals(target({ kind: 'session', id: 'lamp' }), '→ DM lamp')
  assertEquals(target({ kind: 'user', id: 'morgan' }), '→ DM morgan')
  assertEquals(target({ kind: 'conversation', id: 'cv_1' }), '→ cv_1')
  assertEquals(target({ kind: 'report', report: 'progress' }), 'progress')
  assertEquals(target({ kind: 'report', report: 'final' }), 'final report')
})

Deno.test('a wake time shows the date only when it is not today', () => {
  const morning = new Date(1_790_000_000_000)
  const soon = new Date(morning.getTime() + 60_000)
  const tomorrow = new Date(morning.getTime() + 86_400_000)
  // ICU builds differ on the space before the day period.
  const time = (now: Date, locale: string, timeZone: string) =>
    wakeTime(morning, now, locale, timeZone).replace(/\s/g, ' ')
  assertEquals(time(soon, 'en-US', 'UTC'), '2:13 PM')
  assertEquals(time(tomorrow, 'en-US', 'UTC'), 'Sep 21, 2:13 PM')
  assertEquals(time(soon, 'en-GB', 'Asia/Shanghai'), '22:13')
})

Deno.test('an empty transcript loads until the stream is live', () => {
  assertEquals(turnStatus(true, false, false), 'Loading…')
})

Deno.test('a transcript with content reconnects while the stream is down', () => {
  assertEquals(turnStatus(false, false, false), 'Reconnecting…')
})

Deno.test('a live empty transcript says so unless the session is working', () => {
  assertEquals(turnStatus(true, true, false), 'No activity yet.')
  assertEquals(turnStatus(true, true, true), null)
})

Deno.test('a live transcript with content has no status', () => {
  assertEquals(turnStatus(false, true, false), null)
})

Deno.test('a box message and a wake-up tag a request or report alike', () => {
  assertEquals(kindTag('request'), { tag: 'Request', tone: 'request' })
  assertEquals(kindTag('progress'), {
    tag: 'Report · progress',
    tone: 'report',
  })
  assertEquals(kindTag('final'), { tag: 'Report · final', tone: 'report' })
  assertEquals(kindTag('message'), null)
})
