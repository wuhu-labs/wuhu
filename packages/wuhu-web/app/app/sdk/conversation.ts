import { api, inGroup, post } from './http'
import { requireAISharing } from '~/lib/ai-sharing'
import { browserTimezone } from './session'
import { ApiError } from './errors'
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
  viewing?: string | null,
): ConversationPostInput {
  return {
    ...address,
    message,
    timezone,
    ...(replyTarget == null || replyTarget === '' ? {} : { replyTarget }),
    ...(viewing == null ? {} : { viewing }),
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
// message is recorded as sent from there. `viewing` names the doc or page on
// screen at Send (lib/viewing.ts), omitted when there is none. A server that
// refuses it (gone, or no longer readable) gets the message once more
// without it: the page is optional context, the message is not.
export async function postConversationMessage(
  address: MessageAddress,
  group: string,
  message: string,
  replyTarget?: string | null,
  files: readonly File[] = [],
  viewing: string | null = null,
): Promise<ConversationPostOutput> {
  await requireAISharing()
  const send = (viewing: string | null) =>
    api<ConversationPostOutput>(
      '/v1/conversation/message',
      conversationPostRequest(
        conversationPostInput(
          address,
          message,
          browserTimezone(),
          replyTarget,
          viewing,
        ),
        files,
        group,
      ),
    )
  try {
    return await send(viewing)
  } catch (failure) {
    if (viewing === null || !refusesViewing(failure)) throw failure
    // Dropped silently for the person, but not for whoever reads the log.
    // The server's message names the path, so neither is logged.
    console.warn(
      'The server refused viewing (reason viewing); sending without it',
    )
    return send(null)
  }
}

export function refusesViewing(failure: unknown): boolean {
  return failure instanceof ApiError && failure.status === 400 &&
    failure.detail.reason === 'viewing'
}
