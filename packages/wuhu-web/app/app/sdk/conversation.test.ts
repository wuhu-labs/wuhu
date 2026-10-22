import { conversationPostInput, markReadInput } from './conversation.ts'
import { conversationSubscription } from './subscriptions.ts'

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

Deno.test('a box post addresses the backing session, never the conversation', () => {
  assertEquals(
    conversationPostInput(
      { session: 'cave-lime-otter' },
      'hi',
      'Asia/Shanghai',
    ),
    { session: 'cave-lime-otter', message: 'hi', timezone: 'Asia/Shanghai' },
  )
})

Deno.test('a conversation post addresses the conversation id', () => {
  assertEquals(
    conversationPostInput({ conversation: '3f2c' }, 'hi', 'UTC'),
    { conversation: '3f2c', message: 'hi', timezone: 'UTC' },
  )
})

Deno.test('a DM post addresses the user identity', () => {
  assertEquals(
    conversationPostInput({ user: 'morgan' }, 'hi', 'UTC'),
    { user: 'morgan', message: 'hi', timezone: 'UTC' },
  )
})

Deno.test('viewing rides along only when a page is on screen', () => {
  assertEquals(
    conversationPostInput(
      { conversation: 'c' },
      'hi',
      'UTC',
      'wuhu://shared.localspace/notes/plan.md',
    ),
    {
      conversation: 'c',
      message: 'hi',
      timezone: 'UTC',
      viewing: 'wuhu://shared.localspace/notes/plan.md',
    },
  )
  for (const none of [null, undefined]) {
    assertEquals(
      'viewing' in
        conversationPostInput({ session: 's' }, 'hi', 'UTC', none),
      false,
    )
  }
})

Deno.test('the observe stream is cursored on the space-global ordinal', () => {
  const subscription = conversationSubscription('cave-lime-otter', 'shared')
  assertEquals(subscription.from, 0)
  assertEquals(
    subscription.url(null),
    '/v1/conversation/cave-lime-otter/observe?after=0',
  )
  assertEquals(
    subscription.url(412),
    '/v1/conversation/cave-lime-otter/observe?after=412',
  )
  assertEquals(
    subscription.cursorOf({
      n: 412,
      messageId: '9f0a',
      conversationId: 'cave-lime-otter',
      kind: 'message',
      sender: 'owner',
      senderTimezone: 'UTC',
      text: 'hi',
      createdAt: 1756789012.5,
    }),
    412,
  )
})

Deno.test('marking read names the conversation as the watermark source', () => {
  assertEquals(markReadInput('cave-lime-otter'), { source: 'cave-lime-otter' })
})
