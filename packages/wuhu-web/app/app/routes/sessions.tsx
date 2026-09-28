import { useState } from 'react'
import { Link } from 'react-router'
import { Mark, Pill } from '@wuhu/ui'
import { Avatar } from '~/components/avatar'
import { SessionMark } from '~/components/session-row'
import { relativeTime } from '~/lib/relative-time'
import { principalName } from '~/lib/directory'
import { type Branch, nest } from '~/lib/outline'
import { useDirectory, useSessionTitles } from '~/lib/use-directory'
import { type SessionRecord, sessionStatus } from '~/lib/session-model'
import { useSpaceFeeds } from '~/lib/space-feeds'
import { errorMessage } from '~/sdk/errors'
import { archiveSession, unarchiveSession } from '~/sdk/session'
import { sessionHref } from '~/lib/links'

export function stateTone(value: string) {
  if (value === 'errored') return 'rose'
  if (value === 'has_work' || value === 'working') return 'amber'
  return 'neutral'
}

export function meta() {
  return [{ title: 'Agents · Wuhu' }]
}

export default function Sessions() {
  const sessions = useSpaceFeeds().sessions
  const [error, setError] = useState<string | null>(null)
  const now = new Date()

  const act = (work: Promise<void>) => {
    setError(null)
    work.catch((failure: unknown) => setError(errorMessage(failure)))
  }

  const live = sessions?.filter((s) => s.lifecycle !== 'archived') ?? []
  const archived = sessions?.filter((s) => s.lifecycle === 'archived') ?? []

  const branch = (
    { item, children }: Branch<SessionRecord>,
    action: (session: SessionRecord) => { label: string; run: () => void },
  ) => (
    <div key={item.id}>
      <Row session={item} now={now} action={action(item)} />
      {children.length > 0 && (
        <div className='wuhu-session-child'>
          {children.map((child) => branch(child, action))}
        </div>
      )}
    </div>
  )
  const group = (
    list: SessionRecord[],
    action: (session: SessionRecord) => { label: string; run: () => void },
  ) => nest(list).map((root) => branch(root, action))

  return (
    <div className='wuhu-content wuhu-page'>
      <p className='wuhu-eyebrow'>Space</p>
      <h1 className='wuhu-title'>Agents</h1>
      {error && <p className='wuhu-alert wuhu-sessions-error'>{error}</p>}
      {sessions == null && <p className='wuhu-muted'>Loading…</p>}
      {sessions != null && sessions.length === 0 && (
        <p className='wuhu-muted'>No agents yet.</p>
      )}
      {live.length > 0 && (
        <div className='wuhu-session-list'>
          {group(live, (session) => ({
            label: 'Archive',
            run: () => act(archiveSession(session)),
          }))}
        </div>
      )}
      {archived.length > 0 && (
        <>
          <p className='wuhu-eyebrow wuhu-session-list-head'>Archived</p>
          <div className='wuhu-session-list wuhu-session-list-archived'>
            {group(archived, (session) => ({
              label: 'Unarchive',
              run: () => act(unarchiveSession(session)),
            }))}
          </div>
        </>
      )}
    </div>
  )
}

function Row({
  session,
  now,
  action,
}: {
  session: SessionRecord
  now: Date
  action: { label: string; run: () => void }
}) {
  const directory = useDirectory()
  const sessions = useSessionTitles()
  const state = sessionStatus(session)
  return (
    <div className='wuhu-session-item'>
      <Mark size={26} unread={session.unread}>
        <SessionMark session={session} size={26} />
      </Mark>
      <div className='wuhu-session-item-main'>
        <Link to={sessionHref(session.id, session.group)}>{session.title}</Link>
        <span className='wuhu-session-item-model'>
          {session.executorLabel} · by{' '}
          <Avatar principal={session.createdBy} size={18} />{' '}
          <span title={session.createdBy}>
            {principalName(directory, sessions, session.createdBy)}
          </span>
        </span>
      </div>
      <Pill tone='neutral'>{session.kind}</Pill>
      {state && <Pill tone={state.tone} dot>{state.label}</Pill>}
      <span
        className='wuhu-session-item-time'
        title={new Date(session.lastActivityAt).toLocaleString()}
      >
        {relativeTime(session.lastActivityAt, now)}
      </span>
      <button
        type='button'
        className='wuhu-quiet-button'
        onClick={action.run}
      >
        {action.label}
      </button>
    </div>
  )
}
