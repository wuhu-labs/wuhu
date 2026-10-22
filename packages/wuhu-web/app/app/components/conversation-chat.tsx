import { Attachments } from '~/components/attachments'
import { Avatar } from '~/components/avatar'
import { type ChatMessage, ChatView } from '~/components/chat-view'
import { Markdown } from '~/components/markdown-view'
import { orderedMessages } from '~/lib/conversation'
import { senderIsSession, senderName } from '~/lib/directory'
import { crossOriginFor } from '~/lib/groups'
import { useConversation } from '~/lib/use-conversation'
import {
  useDirectory,
  useGroupOrigin,
  useOwnPrincipal,
  useSessionTitles,
} from '~/lib/use-directory'

// A box or a channel as a chat page, read in its own group. Every other
// sender's run carries a name and photo, except the box's own agent's: a
// channel's photos stand in a strip, a box's sit small before the name.
export function ConversationChat({
  conversationId,
  group,
  agent,
}: {
  conversationId: string
  group: string
  // The box's agent; null in a channel.
  agent: string | null
}) {
  const { messages, history } = useConversation(conversationId, group)
  const reader = useOwnPrincipal()
  const directory = useDirectory()
  const sessions = useSessionTitles()
  const origin = useGroupOrigin(group)
  // Nothing is drawn until sides are known, so no message moves once shown.
  if (reader === undefined) return null
  const ordered = orderedMessages(messages)
  const chat = ordered.map((message): ChatMessage => ({
    key: message.messageId,
    sender: message.sender,
    own: message.sender === reader,
    at: new Date(message.createdAt * 1000),
    body: (
      <>
        <Attachments
          attachments={message.attachments ?? []}
          origin={origin}
          crossOrigin={crossOriginFor(group)}
        />
        {message.text !== '' && (
          <div className='wuhu-markdown'>
            <Markdown>{message.text}</Markdown>
          </div>
        )}
      </>
    ),
  }))
  const byId = new Map(ordered.map((message) => [message.sender, message]))
  return (
    <ChatView
      messages={chat}
      history={history}
      identity={conversationId}
      empty='No messages yet.'
      avatars={agent === null ? 'strip' : 'inline'}
      sender={(id) => {
        if (id === agent) return null
        const message = byId.get(id)!
        const fromSession = senderIsSession(sessions, message)
        const name = senderName(directory, message, sessions)
        return {
          name,
          avatar: (
            <Avatar
              principal={id}
              name={fromSession ? name : undefined}
              session={fromSession}
              size={agent === null ? 34 : 18}
            />
          ),
        }
      }}
    />
  )
}
