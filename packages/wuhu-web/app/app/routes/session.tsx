import {
  Navigate,
  useLocation,
  useOutletContext,
  useParams,
} from 'react-router'
import { ConversationChat } from '~/components/conversation-chat'
import { TaskChat } from '~/components/task-chat'
import { type CreatedSession, sessionHref } from '~/lib/links'
import { lookupSession } from '~/lib/session-model'
import { useSpaceFeeds } from '~/lib/space-feeds'
import type { SpaceContext } from '~/routes/space'

export function meta() {
  return [{ title: 'Session · Wuhu' }]
}

// An agent opens as its box's chat; a task as its transcript, drawn the same.
export default function Session() {
  const id = useParams().id!
  const location = useLocation()
  const created = (location.state as CreatedSession | null)?.created === id
  const lookup = lookupSession(useSpaceFeeds().sessions, id, created)
  const { group } = useOutletContext<SpaceContext>()

  if (lookup.kind !== 'found') {
    return (
      <div className='wuhu-chat'>
        <p className='wuhu-chat-empty'>
          {lookup.kind === 'loading'
            ? 'Loading…'
            : `There is no session ${id} in this space.`}
        </p>
      </div>
    )
  }
  const { record } = lookup
  // A link that named no group, or the wrong one, still finds the session.
  if (record.group !== group) {
    return <Navigate replace to={sessionHref(id, record.group)} />
  }
  if (record.kind === 'task') return <TaskChat key={id} record={record} />
  return (
    <ConversationChat
      key={id}
      conversationId={id}
      group={group}
      agent={id}
    />
  )
}
