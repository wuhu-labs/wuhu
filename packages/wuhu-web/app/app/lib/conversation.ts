import type { ConversationMessagePayload } from './contract.gen.ts'

export type MessageMap = ReadonlyMap<string, ConversationMessagePayload>

export function foldMessage(
  current: MessageMap,
  message: ConversationMessagePayload,
): MessageMap {
  const known = current.get(message.messageId)
  if (known != null && known.n === message.n) return current
  return new Map(current).set(message.messageId, message)
}

export function orderedMessages(
  messages: MessageMap,
): ConversationMessagePayload[] {
  return [...messages.values()].sort((a, b) => a.n - b.n)
}
