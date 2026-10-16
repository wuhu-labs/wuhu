import { useLocation, useOutletContext } from 'react-router'
import { ContentFrame } from '~/components/content-frame'
import { DocMeta } from '~/components/doc-meta'
import { FileCard, FileImage } from '~/components/file-view'
import { MarkdownDocument } from '~/components/markdown-document'
import { TableView } from '~/components/table-view'
import type { QueryOutput } from '~/lib/contract.gen'
import type { NodeView } from '~/lib/node-view'
import { tableSubscription } from '~/sdk/subscriptions'
import { spaceDestination } from '~/lib/space-url'
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
  return <NodePage />
}

// Renders the page SpaceBody holds for this address (lib/use-shown-node.ts),
// the same state a send names.
function NodePage() {
  const { group, client, shown } = useOutletContext<SpaceContext>()
  const view: NodeView = shown?.view ?? { state: 'loading' }
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
