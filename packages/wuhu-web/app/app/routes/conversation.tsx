import { Navigate, useOutletContext, useParams } from 'react-router'
import { ConversationChat } from '~/components/conversation-chat'
import { sessionHref } from '~/lib/links'
import { useSpaceFeeds } from '~/lib/space-feeds'
import type { SpaceContext } from '~/routes/space'

export function meta() {
  return [{ title: 'Conversation · Wuhu' }]
}

// A channel. An agent's box reached by its conversation id goes to the
// session's own address, so a box has one page however it was opened.
export default function Conversation() {
  const id = useParams().id!
  const { group } = useOutletContext<SpaceContext>()
  const sessions = useSpaceFeeds().sessions
  if (sessions === null) return null
  const box = sessions.find((session) => session.id === id)
  if (box != null) return <Navigate replace to={sessionHref(id, box.group)} />
  return (
    <ConversationChat key={id} conversationId={id} group={group} agent={null} />
  )
}
