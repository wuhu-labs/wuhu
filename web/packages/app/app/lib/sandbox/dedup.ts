import type { UiMessage } from './types.ts'

export interface QueuedPrompt {
  cursor: number
  message: string
}

export function queuedPromptIsRecordedInCoding(
  prompt: QueuedPrompt,
  codingMessages: UiMessage[],
): boolean {
  return codingMessages.some((m) =>
    m.role === 'user' &&
    m.text === prompt.message &&
    typeof m.cursor === 'number' &&
    m.cursor >= prompt.cursor
  )
}
