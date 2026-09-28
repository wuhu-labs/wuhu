import { useEffect, useState } from 'react'
import { Link, useOutletContext } from 'react-router'
import { Pill } from '@wuhu/ui'
import type { ReadOutput } from '~/lib/contract.gen'
import { entryHref, isSystemAddress } from '~/lib/links'
import { isNotFound, previewLines } from '~/lib/session-context'
import type { SpaceClient } from '~/sdk/client'
import { errorMessage } from '~/sdk/errors'
import { MarkdownDocument } from './markdown-document'
import { MarkdownView } from './markdown-view'
import type { SpaceContext } from '~/routes/space'

type Load =
  | { state: 'loading' }
  | { state: 'error'; message: string }
  | { state: 'missing' }
  | { state: 'ready'; read: ReadOutput }

export function useDocument(
  client: SpaceClient,
  path: string,
): [Load, (next: Load) => void] {
  const [load, setLoad] = useState<Load>({ state: 'loading' })
  useEffect(() => {
    let cancelled = false
    setLoad({ state: 'loading' })
    client.read(path).then(
      (read) => {
        if (!cancelled) setLoad({ state: 'ready', read })
      },
      (failure: unknown) => {
        if (cancelled) return
        setLoad(
          isNotFound(failure)
            ? { state: 'missing' }
            : { state: 'error', message: errorMessage(failure) },
        )
      },
    )
    return () => {
      cancelled = true
    }
  }, [client, path])
  return [load, setLoad]
}

function PathLink({ path }: { path: string }) {
  const { group } = useOutletContext<SpaceContext>()
  return (
    <div className='wuhu-context-entry'>
      <Link className='wuhu-context-path' to={entryHref(path, group)}>
        {path}
      </Link>
      {isSystemAddress(path) && <Pill>System</Pill>}
    </div>
  )
}

function ChainPreview({ content, path }: { content: string; path: string }) {
  const [expanded, setExpanded] = useState(false)
  const preview = previewLines(content)
  return (
    <>
      <MarkdownView
        content={expanded ? content : preview.text}
        sourcePath={path}
      />
      {preview.truncated && (
        <button
          type='button'
          className='wuhu-quiet-button wuhu-context-toggle'
          onClick={() => setExpanded(!expanded)}
        >
          {expanded ? 'Show less' : 'Show all'}
        </button>
      )}
    </>
  )
}

export function ChainAncestor({
  client,
  path,
}: {
  client: SpaceClient
  path: string
}) {
  const [load] = useDocument(client, path)
  return (
    <section className='wuhu-card wuhu-context-card'>
      <PathLink path={path} />
      {load.state === 'loading' && <p className='wuhu-muted'>Loading…</p>}
      {load.state === 'error' && <p className='wuhu-alert'>{load.message}</p>}
      {load.state === 'missing' && (
        <p className='wuhu-muted'>Gone since the chain was resolved.</p>
      )}
      {load.state === 'ready' && (
        <ChainPreview content={load.read.content} path={path} />
      )}
    </section>
  )
}

const briefSeed = '# Brief\n\n'

export function SessionBrief({
  client,
  path,
}: {
  client: SpaceClient
  path: string
}) {
  const [load, setLoad] = useDocument(client, path)
  const [creating, setCreating] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const create = () => {
    setCreating(true)
    setError(null)
    client.write(path, briefSeed).then(
      (output) =>
        setLoad({
          state: 'ready',
          read: { content: briefSeed, token: output.token },
        }),
      (failure: unknown) => {
        setCreating(false)
        setError(errorMessage(failure))
      },
    )
  }

  return (
    <section className='wuhu-card wuhu-context-card'>
      <PathLink path={path} />
      {load.state === 'loading' && <p className='wuhu-muted'>Loading…</p>}
      {load.state === 'error' && <p className='wuhu-alert'>{load.message}</p>}
      {load.state === 'missing' && (
        <>
          <p className='wuhu-muted'>
            No AGENTS.md yet — the brief this session carries into every turn.
          </p>
          {error && <p className='wuhu-alert'>{error}</p>}
          <div>
            <button
              type='button'
              className='wuhu-button'
              disabled={creating}
              onClick={create}
            >
              Create AGENTS.md
            </button>
          </div>
        </>
      )}
      {load.state === 'ready' && (
        <MarkdownDocument client={client} path={path} initial={load.read} />
      )}
    </section>
  )
}
