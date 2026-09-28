import { useEffect, useState } from 'react'
import type {
  ConversationMemberPayload,
  ConversationsOutput,
} from './contract.gen.ts'
import type { SessionSummary } from '~/lib/session-model'
import type { SessionCapability } from './session-capability.ts'
import { api } from '~/sdk/http'
import { errorMessage } from '~/sdk/errors'

type Access = {
  id: string
  members: ConversationMemberPayload[] | null
  error: string | null
}

export function conversationCapability(
  members: ConversationMemberPayload[] | null,
  sessions: SessionSummary[] | null,
): SessionCapability {
  if (members === null || sessions === null) return { kind: 'unknown' }
  return {
    kind: 'conversation',
    allowed: members.every((member) =>
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
        setAccess({ id, members: conversation?.members ?? null, error: null })
      },
      (failure: unknown) => {
        if (!cancelled) {
          setAccess({ id, members: null, error: errorMessage(failure) })
        }
      },
    )
    return () => {
      cancelled = true
    }
  }, [id])
  const members = access?.id === id ? access.members : null
  return {
    capability: conversationCapability(members, sessions),
    members: members ?? [],
    error: access?.id === id ? access.error : null,
  }
}
