import { useEffect, useRef, useState } from 'react'
import { useLocation, useOutletContext } from 'react-router'
import { ContentFrame } from '~/components/content-frame'
import { DocMeta } from '~/components/doc-meta'
import { FileCard, FileImage } from '~/components/file-view'
import { MarkdownDocument } from '~/components/markdown-document'
import { TableView } from '~/components/table-view'
import type { QueryOutput } from '~/lib/contract.gen'
import { cachedThenLive } from '~/lib/cached-then-live'
import { loadNode, type NodeSource, type NodeView } from '~/lib/node-view'
import { type GroupFeed, useSpaceFeeds } from '~/lib/space-feeds'
import { ApiError, errorMessage } from '~/sdk/errors'
import { tableSubscription } from '~/sdk/subscriptions'
import { spaceDestination } from '~/lib/space-url'
import { withoutGroup } from '~/lib/links'
import { useObserve } from '~/lib/use-observe'
import type { SpaceContext } from './space'

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
  const [view, setView] = useState<NodeView>({ state: 'loading' })
  // The tree names a path's kind without a round trip; reading it through a
  // ref keeps every space mutation from reloading the page.
  const feed = useRef<GroupFeed | null>(null)
  feed.current = useSpaceFeeds().feed(group)
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
    const apply = (next: NodeView) => {
      if (!cancelled) setView(next)
    }
    const kept: NodeSource = {
      stat: (at) => {
        if (!feed.current?.loaded) {
          return Promise.reject(new Error('The kept tree is not loaded.'))
        }
        const kind = at === '/' ? 'directory' : feed.current.files.paths.get(at)
        return kind === undefined
          ? Promise.reject(
            new ApiError(404, {
              code: 'notFound',
              message: `${at} is not in the kept tree`,
            }),
          )
          : Promise.resolve({ kind })
      },
      read: (at) => client.keptRead(at),
    }
    const live: NodeSource = {
      stat: (at) => client.stat(at),
      read: (at) => client.read(at),
    }
    cachedThenLive(
      () => loadNode(kept, contentOrigin, path, suffix, viewRev),
      () => loadNode(live, contentOrigin, path, suffix, viewRev),
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
  view: NodeView
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
    case 'image':
      return (
        <FileImage
          group={group}
          path={view.path}
          size={view.size}
          src={view.src}
          remint={client.remintContentSession}
        />
      )
    case 'file':
      return <FileCard path={view.path} size={view.size} src={view.src} />
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
