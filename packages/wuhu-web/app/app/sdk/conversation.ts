import { api, inGroup, post } from './http'
import { requireAISharing } from '~/lib/ai-sharing'
import { browserTimezone } from './session'
import type {
  ConversationPostInput,
  ConversationPostOutput,
} from '~/lib/contract.gen'

// The one shape the contract does not generate: which of the three mutually
// exclusive addressing forms a call site is using.
export type MessageAddress =
  | { conversation: string }
  | { session: string }
  | { user: string }

export function conversationPostInput(
  address: MessageAddress,
  message: string,
  timezone: string,
  replyTarget?: string | null,
): ConversationPostInput {
  return {
    ...address,
    message,
    timezone,
    ...(replyTarget == null || replyTarget === '' ? {} : { replyTarget }),
  }
}

// Advances the caller's watermark on one conversation, which clears its
// unread dot on every device.
export function markConversationRead(
  conversation: string,
  group: string,
): Promise<unknown> {
  return post('/v1/watermark', markReadInput(conversation), inGroup(group))
}

export function markReadInput(conversation: string): { source: string } {
  return { source: conversation }
}

// Files ride as multipart `file` parts after the JSON `message` part; a post
// without files stays plain JSON.
export function conversationPostRequest(
  input: ConversationPostInput,
  files: readonly File[],
  group: string,
): RequestInit {
  if (files.length === 0) {
    return {
      method: 'POST',
      headers: { 'content-type': 'application/json', ...inGroup(group) },
      body: JSON.stringify(input),
    }
  }
  const form = new FormData()
  form.append('message', JSON.stringify(input))
  for (const file of files) form.append('file', file, file.name)
  return { method: 'POST', headers: inGroup(group), body: form }
}

// Posts as a person acting in `group`: the box's own group reads it, and the
// message is recorded as sent from there.
export async function postConversationMessage(
  address: MessageAddress,
  group: string,
  message: string,
  replyTarget?: string | null,
  files: readonly File[] = [],
): Promise<ConversationPostOutput> {
  await requireAISharing()
  return api(
    '/v1/conversation/message',
    conversationPostRequest(
      conversationPostInput(address, message, browserTimezone(), replyTarget),
      files,
      group,
    ),
  )
}
