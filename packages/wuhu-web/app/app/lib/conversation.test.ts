import {
  foldMessage,
  type MessageMap,
  orderedMessages,
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
