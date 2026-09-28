import type { ReactNode } from 'react'
import { ConversationTimeline } from '~/components/conversation-timeline'
import type { ReplyDraft } from '~/lib/conversation'
import { useConversation } from '~/lib/use-conversation'
import type { Liveness } from '~/sdk/observe'

// A conversation is read in its own group: a session's box in the session's.
export function ConversationView({
  conversationId,
  group,
  header,
  onReply,
}: {
  conversationId: string
  group: string
  header: (liveness: Liveness) => ReactNode
  onReply?: (draft: ReplyDraft) => void
}) {
  const { messages, liveness } = useConversation(conversationId, group)
  return (
    <div className='wuhu-content wuhu-page'>
      {header(liveness)}
      <ConversationTimeline
        messages={messages}
        group={group}
        onReply={onReply}
      />
    </div>
  )
}
