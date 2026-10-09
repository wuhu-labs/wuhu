import { useEffect, useState } from 'react'
import type {
  ConversationPayload,
  ConversationsOutput,
} from './contract.gen.ts'
import type { SessionSummary } from '~/lib/session-model'
import type { SessionCapability } from './session-capability.ts'
import { api } from '~/sdk/http'
import { errorMessage } from '~/sdk/errors'

type Access = {
  id: string
  conversation: ConversationPayload | null
  error: string | null
}

export function conversationCapability(
  conversation: Pick<ConversationPayload, 'kind' | 'members'> | null,
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
    api<ConversationsOutput>('/v1/conversations').then(
      (output) => {
        if (cancelled) return
        const conversation = output.conversations.find((found) =>
          found.id === id
        )
        setAccess({ id, conversation: conversation ?? null, error: null })
      },
      (failure: unknown) => {
        if (!cancelled) {
          setAccess({ id, conversation: null, error: errorMessage(failure) })
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
