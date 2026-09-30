import type { ConversationMessagePayload } from './contract.gen.ts'

export type MessageMap = ReadonlyMap<string, ConversationMessagePayload>

export interface ReplyDraft {
  messageId: string
  sender: string
  senderKind?: string | null
  senderHandle?: string | null
  text: string
}

export function replyDraft(
  message: ConversationMessagePayload,
): ReplyDraft {
  return {
    messageId: message.messageId,
    sender: message.sender,
    senderKind: message.senderKind,
    senderHandle: message.senderHandle,
    text: message.text,
  }
}

export type Quote =
  | { kind: 'none' }
  | { kind: 'missing'; messageId: string }
  | { kind: 'quote'; message: ConversationMessagePayload }

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

export function quoteFor(
  messages: MessageMap,
  message: ConversationMessagePayload,
): Quote {
  const target = message.replyTarget
  if (target == null || target === '') return { kind: 'none' }
  const found = messages.get(target)
  if (found == null) return { kind: 'missing', messageId: target }
  return { kind: 'quote', message: found }
}

export function quoteExcerpt(text: string, limit = 140): string {
  const flat = text.replace(/\s+/g, ' ').trim()
  return flat.length <= limit ? flat : `${flat.slice(0, limit)}…`
}

// Who is reading decides which side a message sits on. While the reader is
// still being resolved there is no answer yet; a reader known to have no
// principal owns nothing.
export function ownerOf(
  reader: string | null | undefined,
): ((sender: string) => boolean) | null {
  if (reader === undefined) return null
  return (sender) => sender === reader
}
