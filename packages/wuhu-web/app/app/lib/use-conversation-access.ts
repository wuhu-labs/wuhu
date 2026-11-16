import { useEffect, useState } from 'react'
import type { ConversationDetail } from './contract.gen.ts'
import type { SessionSummary } from '~/lib/session-model'
import type { SessionCapability } from './session-capability.ts'
import { api } from '~/sdk/http'
import { ApiError, errorMessage } from '~/sdk/errors'

type Access = {
  id: string
  conversation: ConversationDetail | null
  error: string | null
}

// The list this replaced answered a conversation the reader was not in as absent, not as an error.
export function accessFailureMessage(failure: unknown): string | null {
  return failure instanceof ApiError && failure.status === 404
    ? null
    : errorMessage(failure)
}

export function conversationCapability(
  conversation: Pick<ConversationDetail, 'kind' | 'members'> | null,
  sessions: SessionSummary[] | null,
): SessionCapability {
  if (conversation === null) return { kind: 'unknown' }
  if (
    conversation.kind === 'dm_user' &&
    conversation.members.some((member) => member.kind === 'session')
  ) {
    return { kind: 'conversation', allowed: false }
  }
  if (sessions === null) return { kind: 'unknown' }
  return {
    kind: 'conversation',
    allowed: conversation.members.every((member) =>
      member.kind !== 'session' ||
      sessions.some((session) =>
        session.id === member.member && session.kind === 'agent' &&
        session.lifecycle !== 'archived'
      )
    ),
  }
}

export function useConversationAccess(
  id: string | null,
  sessions: SessionSummary[] | null,
) {
  const [access, setAccess] = useState<Access | null>(null)
  useEffect(() => {
    if (id === null) return
    let cancelled = false
    api<ConversationDetail>(`/v1/conversation/${encodeURIComponent(id)}`).then(
      (conversation) => {
        if (!cancelled) setAccess({ id, conversation, error: null })
      },
      (failure: unknown) => {
        if (!cancelled) {
          setAccess({
            id,
            conversation: null,
            error: accessFailureMessage(failure),
          })
        }
      },
    )
    return () => {
      cancelled = true
    }
  }, [id])
  const conversation = access?.id === id ? access.conversation : null
  return {
    capability: conversationCapability(conversation, sessions),
    members: conversation?.members ?? [],
    error: access?.id === id ? access.error : null,
  }
}
