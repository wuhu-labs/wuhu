import { useOutletContext, useParams } from 'react-router'
import { Pill } from '@wuhu/ui'
import { ConversationView } from '~/components/conversation-view'
import { PageHeading } from '~/components/page-heading'
import { memberName } from '~/lib/directory'
import { useDirectory } from '~/lib/use-directory'
import type { SpaceContext } from '~/routes/space'

export function meta() {
  return [{ title: 'Conversation · Wuhu' }]
}

export default function Conversation() {
  const id = useParams().id!
  const { group, replyTo, members, conversationError } = useOutletContext<
    SpaceContext
  >()
  const directory = useDirectory()
  return (
    <ConversationView
      key={id}
      conversationId={id}
      group={group}
      header={(liveness) => (
        <header className='wuhu-session-header'>
          {conversationError && (
            <p className='wuhu-alert' role='alert'>
              Could not load conversation access: {conversationError}
            </p>
          )}
          <PageHeading title={id} group={group} />
          <div className='wuhu-session-meta'>
            {members.map((member) => (
              <Pill key={member.member} tone='neutral'>
                <span title={member.member}>
                  {memberName(directory, member)}
                </span>
              </Pill>
            ))}
            {liveness !== 'live' && <Pill tone='amber' dot>reconnecting</Pill>}
          </div>
        </header>
      )}
      onReply={replyTo ?? undefined}
    />
  )
}
