import { useEffect, useState } from 'react'
import { Link, useLocation, useOutletContext } from 'react-router'
import { Pill } from '@wuhu/ui'
import { Avatar } from '~/components/avatar'
import { PageHeading } from '~/components/page-heading'
import type { SpaceContext } from '~/routes/space'
import { principalName } from '~/lib/directory'
import { sessionHref, type SessionView, sessionView } from '~/lib/links'
import { useDirectory, useSessionTitles } from '~/lib/use-directory'
import { stateTone } from '~/routes/sessions'
import type { Liveness } from '~/sdk/observe'
import type { SessionContext } from '~/lib/contract.gen'
import { fetchSessionContext } from '~/sdk/session'
import type { SessionRecord } from '~/lib/session-model'

function contextTone(percentage: number): 'rose' | 'amber' | 'neutral' {
  if (percentage >= 90) return 'rose'
  if (percentage >= 70) return 'amber'
  return 'neutral'
}

function ContextPill({ context }: { context: SessionContext }) {
  const title =
    `${context.usedTokens.toLocaleString()} / ${context.maxTokens.toLocaleString()} tokens · ${context.source}`
  return (
    <Pill tone={contextTone(context.percentage)}>
      <span title={title}>context {context.percentage.toFixed(1)}%</span>
    </Pill>
  )
}

export function SessionHeader({
  id,
  record,
  liveness,
}: {
  id: string
  record: SessionRecord | null
  liveness: Liveness
}) {
  const directory = useDirectory()
  const sessions = useSessionTitles()
  const { search } = useLocation()
  const { group } = useOutletContext<SpaceContext>()
  const [context, setContext] = useState<SessionContext | null>(null)
  const work = record?.work

  useEffect(() => {
    let cancelled = false
    fetchSessionContext({ id, group }).then(
      (found) => {
        if (!cancelled) setContext(found)
      },
      () => undefined,
    )
    return () => {
      cancelled = true
    }
  }, [id, group, liveness, work])

  const agent = record?.kind === 'agent'
  const view = sessionView(search) ?? (agent ? null : 'transcript')
  return (
    <header className='wuhu-session-header'>
      <PageHeading title={record?.title ?? id.slice(0, 8)} group={group} />
      <div className='wuhu-session-meta'>
        {record && (
          <>
            <Pill tone='neutral'>{record.kind}</Pill>
            <span className='wuhu-mono'>{record.executorLabel}</span>
            <Avatar principal={record.createdBy} size={18} />
            <span className='wuhu-mono' title={record.createdBy}>
              by {principalName(directory, sessions, record.createdBy)}
            </span>
            <Pill tone={stateTone(record.hold)}>{record.hold}</Pill>
            <Pill tone={stateTone(record.work)}>{record.work}</Pill>
            <Pill tone={stateTone(record.lifecycle)}>{record.lifecycle}</Pill>
          </>
        )}
        {context && <ContextPill context={context} />}
        {liveness !== 'live' && <Pill tone='amber' dot>reconnecting</Pill>}
        <nav className='wuhu-tabs'>
          {agent && (
            <Tab id={id} group={group} view={null} current={view}>box</Tab>
          )}
          <Tab id={id} group={group} view='transcript' current={view}>
            transcript
          </Tab>
          <Tab id={id} group={group} view='context' current={view}>
            context
          </Tab>
        </nav>
      </div>
      {record?.errorMessage && (
        <p className='wuhu-alert'>{record.errorMessage}</p>
      )}
    </header>
  )
}

function Tab({
  id,
  group,
  view,
  current,
  children,
}: {
  id: string
  group: string
  view: SessionView | null
  current: SessionView | null
  children: string
}) {
  const active = view === current
  return (
    <Link
      to={sessionHref(id, group, view ?? undefined)}
      className={active ? 'active' : undefined}
      aria-current={active ? 'page' : undefined}
    >
      {children}
    </Link>
  )
}
