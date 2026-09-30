import { directoryOf, senderName } from './directory.ts'
import {
  foldMessage,
  type MessageMap,
  orderedMessages,
  ownerOf,
  quoteExcerpt,
  quoteFor,
  replyDraft,
} from './conversation.ts'
import type { ConversationMessagePayload } from './contract.gen.ts'

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

function message(
  n: number,
  messageId: string,
  patch: Partial<ConversationMessagePayload> = {},
): ConversationMessagePayload {
  return {
    n,
    messageId,
    conversationId: 'cave-lime-otter',
    kind: 'message',
    sender: 'owner',
    senderKind: 'user',
    senderTimezone: 'Asia/Shanghai',
    text: `message ${messageId}`,
    createdAt: 1756789012.5,
    ...patch,
  }
}

function mapOf(...messages: ConversationMessagePayload[]): MessageMap {
  return messages.reduce(foldMessage, new Map() as MessageMap)
}

Deno.test('messages are keyed by id and ordered by the space-global ordinal', () => {
  const map = mapOf(message(412, 'c'), message(9, 'a'), message(77, 'b'))
  assertEquals(orderedMessages(map).map((m) => m.messageId), ['a', 'b', 'c'])
})

Deno.test('a repeated message id keeps the map identity so a redelivery is inert', () => {
  const first = mapOf(message(9, 'a'))
  assertEquals(foldMessage(first, message(9, 'a')) === first, true)
})

Deno.test('a message whose ordinal moved replaces the stored copy', () => {
  const first = mapOf(message(9, 'a'))
  const second = foldMessage(first, message(10, 'a'))
  assertEquals(second === first, false)
  assertEquals(second.get('a')?.n, 10)
})

Deno.test('a message with no reply target quotes nothing', () => {
  const target = message(9, 'a')
  assertEquals(quoteFor(mapOf(target), target).kind, 'none')
  assertEquals(
    quoteFor(mapOf(target), message(10, 'b', { replyTarget: '' })).kind,
    'none',
  )
})

Deno.test('a reply target present in the page resolves to the quoted message', () => {
  const target = message(9, 'a', { sender: 'hare-teal-plum', text: 'on it' })
  const reply = message(10, 'b', { replyTarget: 'a' })
  const quote = quoteFor(mapOf(target, reply), reply)
  if (quote.kind !== 'quote') {
    throw new Error(`expected a quote, got ${quote.kind}`)
  }
  assertEquals(quote.message.sender, 'hare-teal-plum')
  assertEquals(quote.message.text, 'on it')
})

Deno.test('a reply target outside the page is reported missing, not dropped', () => {
  const reply = message(10, 'b', { replyTarget: 'gone' })
  assertEquals(quoteFor(mapOf(reply), reply), {
    kind: 'missing',
    messageId: 'gone',
  })
})

Deno.test('a quote excerpt collapses whitespace and clips to one line', () => {
  assertEquals(quoteExcerpt('  a\n\n  b  \tc '), 'a b c')
  assertEquals(quoteExcerpt('abcdef', 3), 'abc…')
  assertEquals(quoteExcerpt('abc', 3), 'abc')
})

Deno.test('a reply draft keeps the sender id and kind for presentation-time resolution', () => {
  assertEquals(
    replyDraft(
      message(9, 'a', {
        sender: 'owner',
        senderKind: 'user',
        senderHandle: 'old',
        text: 'hi',
      }),
    ),
    {
      messageId: 'a',
      sender: 'owner',
      senderKind: 'user',
      senderHandle: 'old',
      text: 'hi',
    },
  )
})

Deno.test('the reader decides sides once resolved, and owns nothing without a principal', () => {
  assertEquals(ownerOf(undefined), null)
  const none = ownerOf(null)!
  assertEquals([none('morgan'), none('spoon')], [false, false])
  const known = ownerOf('morgan')!
  assertEquals([known('morgan'), known('spoon')], [true, false])
})

Deno.test('a pending reply resolves against the current directory without changing its sender id', () => {
  const draft = replyDraft(
    message(9, 'a', {
      sender: 'person',
      senderKind: 'user',
      senderHandle: 'old',
      text: 'hi',
    }),
  )
  assertEquals(draft.sender, 'person')
  assertEquals(
    senderName(directoryOf([{ id: 'person', handle: 'vivian' }]), draft),
    '@vivian',
  )
  assertEquals(
    senderName(
      directoryOf([{
        id: 'person',
        handle: 'vivian',
        displayName: 'Vivian Cao',
      }]),
      draft,
    ),
    'Vivian Cao',
  )
})
