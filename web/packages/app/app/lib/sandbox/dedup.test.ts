import { assert, assertEquals } from '@std/assert'
import { queuedPromptIsRecordedInCoding } from './dedup.ts'
import type { UiMessage } from './types.ts'

function msg(overrides: Partial<UiMessage>): UiMessage {
  return {
    id: overrides.id ?? 'm1',
    role: overrides.role ?? 'assistant',
    title: overrides.title ?? 'Agent',
    text: overrides.text ?? '',
    status: overrides.status ?? 'complete',
    cursor: overrides.cursor,
    timestamp: overrides.timestamp,
    thinking: overrides.thinking,
    toolCalls: overrides.toolCalls,
  }
}

Deno.test('queuedPromptIsRecordedInCoding matches later user message', () => {
  const recorded = queuedPromptIsRecordedInCoding(
    { cursor: 10, message: 'hello' },
    [msg({ role: 'user', text: 'hello', cursor: 11 })],
  )
  assert(recorded)
})

Deno.test('queuedPromptIsRecordedInCoding does not match earlier user message', () => {
  const recorded = queuedPromptIsRecordedInCoding(
    { cursor: 10, message: 'hello' },
    [msg({ role: 'user', text: 'hello', cursor: 9 })],
  )
  assertEquals(recorded, false)
})

Deno.test('queuedPromptIsRecordedInCoding ignores non-user messages', () => {
  const recorded = queuedPromptIsRecordedInCoding(
    { cursor: 10, message: 'hello' },
    [msg({ role: 'assistant', text: 'hello', cursor: 11 })],
  )
  assertEquals(recorded, false)
})

Deno.test('queuedPromptIsRecordedInCoding ignores messages without cursors', () => {
  const recorded = queuedPromptIsRecordedInCoding(
    { cursor: 10, message: 'hello' },
    [msg({ role: 'user', text: 'hello' })],
  )
  assertEquals(recorded, false)
})
