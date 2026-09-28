import {
  conversationPostInput,
  conversationPostRequest,
  markReadInput,
} from './conversation.ts'
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

Deno.test('replyTarget rides along only when one was picked', () => {
  assertEquals(
    conversationPostInput({ session: 's' }, 'hi', 'UTC', '9f0a'),
    { session: 's', message: 'hi', timezone: 'UTC', replyTarget: '9f0a' },
  )
  for (const empty of [null, undefined, '']) {
    assertEquals(
      'replyTarget' in
        conversationPostInput({ session: 's' }, 'hi', 'UTC', empty),
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

Deno.test('a post without files is plain JSON', () => {
  const input = conversationPostInput({ session: 's' }, 'hi', 'UTC')
  const request = conversationPostRequest(input, [], 'shared')
  assertEquals(request.headers, {
    'content-type': 'application/json',
    'wuhu-group': 'shared',
  })
  assertEquals(request.body, JSON.stringify(input))
})

Deno.test('files go as multipart: one message part, then a file part each', async () => {
  const input = conversationPostInput({ session: 's' }, '', 'UTC')
  const files = [
    new File(['png'], 'a.png', { type: 'image/png' }),
    new File(['%PDF'], 'b.pdf', { type: 'application/pdf' }),
  ]
  const request = conversationPostRequest(input, files, 'sail-clock-pepper')
  assertEquals(request.headers, { 'wuhu-group': 'sail-clock-pepper' })
  const form = request.body as FormData
  assertEquals([...form.keys()], ['message', 'file', 'file'])
  assertEquals(JSON.parse(form.get('message') as string), input)
  const parts = form.getAll('file') as File[]
  assertEquals(parts.map((part) => [part.name, part.type]), [
    ['a.png', 'image/png'],
    ['b.pdf', 'application/pdf'],
  ])
  assertEquals(await parts[1].text(), '%PDF')
})
