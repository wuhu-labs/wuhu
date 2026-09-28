import { useEffect, useState } from 'react'
import { useOutletContext } from 'react-router'
import { SessionHeader } from '~/components/session-header'
import { ChainAncestor, SessionBrief } from '~/components/session-context-chain'
import {
  SessionHomeFiles,
  SessionSkills,
} from '~/components/session-context-home'
import type { SessionHomeOutput } from '~/lib/contract.gen'
import { splitChain } from '~/lib/session-context'
import { useSessionRecord } from '~/lib/use-session'
import type { SpaceClient } from '~/sdk/client'
import { errorMessage } from '~/sdk/errors'
import { fetchSessionHome } from '~/sdk/session'
import type { SpaceContext } from '~/routes/space'

export function SessionContextView({ id }: { id: string }) {
  const record = useSessionRecord(id)
  const { client, group } = useOutletContext<SpaceContext>()
  const [home, setHome] = useState<SessionHomeOutput | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    setHome(null)
    setError(null)
    fetchSessionHome({ id, group }).then(
      (found) => {
        if (!cancelled) setHome(found)
      },
      (failure: unknown) => {
        if (!cancelled) setError(errorMessage(failure))
      },
    )
    return () => {
      cancelled = true
    }
  }, [id, group])

  return (
    <div className='wuhu-content wuhu-page'>
      <SessionHeader id={id} record={record} liveness='live' />
      {error && <p className='wuhu-alert'>{error}</p>}
      {home == null
        ? error == null ? <p className='wuhu-muted'>Loading…</p> : null
        : <ContextBody client={client} home={home} />}
    </div>
  )
}

function ContextBody({
  client,
  home,
}: {
  client: SpaceClient
  home: SessionHomeOutput
}) {
  const { ancestors, own } = splitChain(home.chain, home.home)
  return (
    <div className='wuhu-context'>
      <section className='wuhu-context-section'>
        <p className='wuhu-eyebrow'>Context</p>
        <p className='wuhu-muted'>
          What this session's prompt holds: the system AGENTS.md and skills,
          then the space's and its home's. The list is frozen at the session's
          prompt revision, so it changes only at compaction or Start over;
          opening a space or home entry shows the latest file.
        </p>
        <span className='wuhu-context-path'>{home.home}/</span>
      </section>
      <section className='wuhu-context-section'>
        {ancestors.map((path) => (
          <ChainAncestor key={path} client={client} path={path} />
        ))}
        <SessionBrief client={client} path={own} />
      </section>
      <SessionSkills skills={home.skills} />
      <SessionHomeFiles client={client} home={home.home} />
    </div>
  )
}
