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
  viewing?: string | null,
): ConversationPostInput {
  return {
    ...address,
    message,
    timezone,
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

// Posts as a person acting in `group`: the box's own group reads it, and the
// message is recorded as sent from there. `viewing` names the doc or page on
// screen at Send (lib/viewing.ts), omitted when there is none. A server that
// refuses it (gone, or no longer readable) gets the message once more
// without it: the page is optional context, the message is not.
export async function postConversationMessage(
  address: MessageAddress,
  group: string,
  message: string,
  viewing: string | null = null,
): Promise<ConversationPostOutput> {
  await requireAISharing()
  const send = (viewing: string | null) =>
    api<ConversationPostOutput>('/v1/conversation/message', {
      method: 'POST',
      headers: { 'content-type': 'application/json', ...inGroup(group) },
      body: JSON.stringify(
        conversationPostInput(address, message, browserTimezone(), viewing),
      ),
    })
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
