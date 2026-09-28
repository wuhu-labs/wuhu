import { useEffect, useRef, useState } from 'react'
import { useLocation, useOutletContext } from 'react-router'
import { ContentFrame } from '~/components/content-frame'
import { DocMeta } from '~/components/doc-meta'
import { MarkdownDocument } from '~/components/markdown-document'
import { TableView } from '~/components/table-view'
import type { EntryKind, QueryOutput, ReadOutput } from '~/lib/contract.gen'
import { cachedThenLive } from '~/lib/cached-then-live'
import { useSpaceFeeds } from '~/lib/space-feeds'
import type { PathMap } from '~/lib/tree'
import { errorMessage } from '~/sdk/errors'
import { tableSubscription } from '~/sdk/subscriptions'
import { spaceDestination } from '~/lib/space-url'
import { withoutGroup } from '~/lib/links'
import { useObserve } from '~/lib/use-observe'
import { viewOpening } from '~/lib/view-opening'
import type { SpaceContext } from './space'

type View =
  | { state: 'loading' }
  | { state: 'error'; message: string }
  | { state: 'markdown'; content: string; path: string; token: string }
  | { state: 'text'; content: string; notice?: string }
  | { state: 'html'; origin: string; src: string }
  | { state: 'binary' }
  | { state: 'table'; path: string }

export default function Node() {
  const location = useLocation()
  const destination = spaceDestination(location.pathname)
  if (destination?.kind !== 'path') {
    return (
      <div className='wuhu-content wuhu-page'>
        <p className='wuhu-alert'>Nothing lives at this address.</p>
      </div>
    )
  }
  return <NodePage path={destination.path} />
}

function NodePage({ path }: { path: string }) {
  const { group, client, contentOrigin, viewRevs } = useOutletContext<
    SpaceContext
  >()
  const location = useLocation()
  const suffix = withoutGroup(location.search) + location.hash
  const viewRev = viewRevs[path] ?? 0
  const [view, setView] = useState<View>({ state: 'loading' })
  // The tree names a path's kind without a round trip; reading it through a
  // ref keeps every space mutation from reloading the page.
  const paths = useRef<PathMap>(new Map())
  paths.current = useSpaceFeeds().feed(group).files.paths
  const [active, setActive] = useState({
    client,
    contentOrigin,
    path,
    suffix,
    viewRev,
  })
  if (
    active.client !== client ||
    active.contentOrigin !== contentOrigin ||
    active.path !== path ||
    active.suffix !== suffix ||
    active.viewRev !== viewRev
  ) {
    setActive({ client, contentOrigin, path, suffix, viewRev })
    setView({ state: 'loading' })
  }

  useEffect(() => {
    let cancelled = false
    const apply = (next: View) => {
      if (!cancelled) setView(next)
    }
    const kept: Source = {
      kind: (at) => {
        const kind = at === '/' ? 'directory' : paths.current.get(at)
        return kind === undefined
          ? Promise.reject(new Error(`${at} is not in the kept tree`))
          : Promise.resolve(kind)
      },
      read: (at) => client.keptRead(at),
    }
    const live: Source = {
      kind: (at) => client.stat(at).then((entry) => entry.kind),
      read: (at) => client.read(at),
    }
    cachedThenLive(
      () => load(kept, contentOrigin, path, suffix, viewRev),
      () => load(live, contentOrigin, path, suffix, viewRev),
      apply,
      (failure) => apply({ state: 'error', message: errorMessage(failure) }),
    )
    return () => {
      cancelled = true
    }
  }, [client, contentOrigin, path, suffix, viewRev])

  const reading = view.state === 'markdown'
  return (
    <div
      className={reading
        ? 'wuhu-content wuhu-page'
        : 'wuhu-content wuhu-page wuhu-page-wide'}
    >
      <NodeBody group={group} client={client} view={view} />
    </div>
  )
}

function NodeBody({
  group,
  client,
  view,
}: {
  group: string
  client: SpaceContext['client']
  view: View
}) {
  switch (view.state) {
    case 'loading':
      return <p className='wuhu-muted'>Loading…</p>
    case 'error':
      return <p className='wuhu-alert'>{view.message}</p>
    case 'markdown':
      return (
        <>
          <DocMeta path={view.path} group={group} />
          <MarkdownDocument
            client={client}
            path={view.path}
            initial={{ content: view.content, token: view.token }}
          />
        </>
      )
    case 'text':
      return (
        <>
          {view.notice && <p className='wuhu-muted'>{view.notice}</p>}
          <pre className='wuhu-text'>{view.content}</pre>
        </>
      )
    case 'html':
      return (
        <ContentFrame
          group={group}
          origin={view.origin}
          src={view.src}
          remint={client.remintContentSession}
        />
      )
    case 'binary':
      return (
        <p className='wuhu-muted'>
          Binary content — no viewer for this file yet.
        </p>
      )
    case 'table':
      return <LiveTable path={view.path} group={group} />
  }
}

const noRows: QueryOutput = { columns: [], rows: [] }

function LiveTable({ path, group }: { path: string; group: string }) {
  const output = useObserve<QueryOutput, QueryOutput>(
    tableSubscription(path, group),
    (_, next) => next,
    noRows,
  ).data
  return <TableView output={output} />
}

interface Source {
  kind(path: string): Promise<EntryKind>
  read(path: string): Promise<ReadOutput>
}

async function load(
  source: Source,
  contentOrigin: SpaceContext['contentOrigin'],
  path: string,
  suffix: string,
  viewRev: number,
): Promise<View> {
  const kind = await source.kind(path)
  if (kind === 'table') return { state: 'table', path }
  if (kind === 'directory') {
    const origin = resolvedContentOrigin(contentOrigin)
    if (origin === undefined) return { state: 'loading' }
    if (origin != null) {
      const directory = path === '/' ? path : `${path}/`
      return {
        state: 'html',
        origin,
        src: origin + encodeURI(directory) + suffix,
      }
    }
    return { state: 'error', message: 'Server reports no web origin.' }
  }
  if (path.endsWith('.html') || path.endsWith('.htm')) {
    const origin = resolvedContentOrigin(contentOrigin)
    if (origin === undefined) return { state: 'loading' }
    if (origin) {
      return {
        state: 'html',
        origin,
        src: origin + encodeURI(path) + suffix,
      }
    }
    const { content } = await source.read(path)
    return {
      state: 'text',
      content,
      notice: 'Server reports no web origin — showing raw HTML.',
    }
  }
  if (path.endsWith('.view')) {
    const { content } = await source.read(path)
    const opening = viewOpening(content)
    if (opening.state === 'text') return opening
    const doc = opening.doc
    const origin = resolvedContentOrigin(contentOrigin)
    if (origin === undefined) return { state: 'loading' }
    if (!origin) {
      return {
        state: 'text',
        content,
        notice: 'Server reports no web origin — showing the raw view doc.',
      }
    }
    const params = new URLSearchParams({ path, rev: String(viewRev) })
    return {
      state: 'html',
      origin,
      src: `${origin}/_/views/${encodeURIComponent(doc.view)}?${params}`,
    }
  }
  const { content, token } = await source.read(path)
  if (content.includes('\u0000')) return { state: 'binary' }
  if (path.endsWith('.md') || path.endsWith('.markdown')) {
    return { state: 'markdown', content, path, token }
  }
  return { state: 'text', content }
}

function resolvedContentOrigin(
  contentOrigin: SpaceContext['contentOrigin'],
): string | null | undefined {
  if (contentOrigin instanceof Error) throw contentOrigin
  return contentOrigin
}
