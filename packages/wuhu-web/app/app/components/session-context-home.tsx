import { useEffect, useState } from 'react'
import { Link, useOutletContext } from 'react-router'
import { Pill } from '@wuhu/ui'
import type { Entry, SessionHomeSkill } from '~/lib/contract.gen'
import { entryHref, fileHref, isSystemAddress } from '~/lib/links'
import { isNotFound, sizeLabel } from '~/lib/session-context'
import type { SpaceClient } from '~/sdk/client'
import { errorMessage } from '~/sdk/errors'
import { NewDocumentDialog } from './new-document'
import type { SpaceContext } from '~/routes/space'

export function SessionSkills({ skills }: { skills: SessionHomeSkill[] }) {
  const { group } = useOutletContext<SpaceContext>()
  return (
    <section className='wuhu-context-section'>
      <p className='wuhu-eyebrow'>Skills</p>
      {skills.length === 0
        ? <p className='wuhu-muted'>No skills on this chain.</p>
        : skills.map((skill) => (
          <div className='wuhu-session-item wuhu-context-row' key={skill.path}>
            <div className='wuhu-session-item-main'>
              <span className='wuhu-context-name'>{skill.name}</span>
              {isSystemAddress(skill.path) && <Pill>System</Pill>}
              <span className='wuhu-muted'>{skill.description}</span>
            </div>
            <span className='wuhu-context-path'>{skill.path}</span>
            <Link
              className='wuhu-quiet-button'
              to={entryHref(skill.path, group)}
            >
              Open
            </Link>
          </div>
        ))}
    </section>
  )
}

type Listing =
  | { state: 'loading' }
  | { state: 'error'; message: string }
  | { state: 'missing' }
  | { state: 'ready'; entries: Entry[] }

export function SessionHomeFiles({
  client,
  home,
}: {
  client: SpaceClient
  home: string
}) {
  const [listing, setListing] = useState<Listing>({ state: 'loading' })
  const [dialog, setDialog] = useState(false)

  useEffect(() => {
    let cancelled = false
    setListing({ state: 'loading' })
    client.ls(home, true).then(
      (output) => {
        if (!cancelled) setListing({ state: 'ready', entries: output.entries })
      },
      (failure: unknown) => {
        if (cancelled) return
        setListing(
          isNotFound(failure)
            ? { state: 'missing' }
            : { state: 'error', message: errorMessage(failure) },
        )
      },
    )
    return () => {
      cancelled = true
    }
  }, [client, home])

  const entries = listing.state === 'ready' ? listing.entries : []
  return (
    <section className='wuhu-context-section'>
      <div className='wuhu-context-head'>
        <p className='wuhu-eyebrow'>Home</p>
        <button
          type='button'
          className='wuhu-quiet-button'
          onClick={() => setDialog(true)}
        >
          New file
        </button>
      </div>
      <span className='wuhu-context-path'>{home}/</span>
      {listing.state === 'loading' && <p className='wuhu-muted'>Loading…</p>}
      {listing.state === 'error' && (
        <p className='wuhu-alert'>{listing.message}</p>
      )}
      {listing.state === 'missing' && (
        <p className='wuhu-muted'>Not created yet.</p>
      )}
      {listing.state === 'ready' && entries.length === 0 && (
        <p className='wuhu-muted'>Nothing here yet.</p>
      )}
      {entries.map((entry) => (
        <div className='wuhu-session-item wuhu-context-row' key={entry.name}>
          <div className='wuhu-session-item-main'>
            <Link to={fileHref(`${home}/${entry.name}`, client.group)}>
              {entry.name}
            </Link>
            {entry.kind !== 'file' && <Pill tone='neutral'>{entry.kind}</Pill>}
          </div>
          <span className='wuhu-context-path'>{sizeLabel(entry.size)}</span>
        </div>
      ))}
      <NewDocumentDialog
        client={client}
        directory={dialog ? home : null}
        exists={(path) =>
          entries.some((entry) => `${home}/${entry.name}` === path)}
        onClose={() => setDialog(false)}
      />
    </section>
  )
}
