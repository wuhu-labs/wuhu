import { latestOrdinal, ReadMark } from './read-mark.ts'
import type { MessageMap } from './conversation.ts'
import type { ConversationMessagePayload } from './contract.gen.ts'

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

function log(...ordinals: number[]): MessageMap {
  return new Map(
    ordinals.map((n) => [
      `msg_${n}`,
      { n, messageId: `msg_${n}` } as ConversationMessagePayload,
    ]),
  )
}

Deno.test('opening a conversation marks it read once it is live and visible', () => {
  const mark = new ReadMark()
  assertEquals(mark.advance(latestOrdinal(log(3, 7)), true, false), false)
  assertEquals(mark.advance(latestOrdinal(log(3, 7)), true, true), true)
  assertEquals(mark.advance(latestOrdinal(log(3, 7)), true, true), false)
})

Deno.test('an empty conversation is marked read when it opens', () => {
  const mark = new ReadMark()
  assertEquals(latestOrdinal(log()), 0)
  assertEquals(mark.advance(latestOrdinal(log()), true, true), true)
})

Deno.test('a newer message marks again only while the page is read', () => {
  const mark = new ReadMark()
  mark.advance(7, true, true)
  assertEquals(mark.advance(9, false, true), false)
  assertEquals(mark.advance(9, true, true), true)
})

Deno.test('regaining focus marks again, so a failed mark gets its retry', () => {
  const mark = new ReadMark()
  assertEquals(mark.advance(7, true, true), true)
  assertEquals(mark.advance(7, false, true), false)
  assertEquals(mark.advance(7, true, true), true)
  assertEquals(mark.advance(7, true, true), false)
})
