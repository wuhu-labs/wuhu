import {
  Navigate,
  useLocation,
  useOutletContext,
  useParams,
} from 'react-router'
import { ConversationView } from '~/components/conversation-view'
import { SessionContextView } from '~/components/session-context-view'
import { SessionHeader } from '~/components/session-header'
import { SessionTranscript } from '~/components/session-transcript'
import { type CreatedSession, sessionHref, sessionView } from '~/lib/links'
import { lookupSession } from '~/lib/session-model'
import { useSpaceFeeds } from '~/lib/space-feeds'
import type { SpaceContext } from '~/routes/space'

export function meta() {
  return [{ title: 'Session · Wuhu' }]
}

export default function Session() {
  const id = useParams().id!
  const location = useLocation()
  const view = sessionView(location.search)
  const created = (location.state as CreatedSession | null)?.created === id
  const lookup = lookupSession(useSpaceFeeds().sessions, id, created)
  const { group, replyTo } = useOutletContext<SpaceContext>()

  if (lookup.kind !== 'found') {
    return (
      <div className='wuhu-content wuhu-page'>
        {lookup.kind === 'loading' ? <p className='wuhu-muted'>Loading…</p> : (
          <>
            <h1 className='wuhu-title'>Session not found</h1>
            <p className='wuhu-muted'>
              There is no session <code>{id}</code> in this space.
            </p>
          </>
        )}
      </div>
    )
  }
  const { record } = lookup
  // A link that named no group, or the wrong one, still finds the session.
  if (record.group !== group) {
    return (
      <Navigate
        replace
        to={sessionHref(id, record.group, view ?? undefined)}
      />
    )
  }
  if (view === 'context') return <SessionContextView id={id} />
  if (view === 'transcript' || record.kind !== 'agent') {
    return <SessionTranscript id={id} record={record} />
  }
  return (
    <ConversationView
      key={id}
      conversationId={id}
      group={group}
      header={(liveness) => (
        <SessionHeader id={id} record={record} liveness={liveness} />
      )}
      onReply={replyTo ?? undefined}
    />
  )
}
