import { Link, useOutletContext } from 'react-router'
import { useShell } from '@wuhu/ui'
import { ContentFrame } from '~/components/content-frame'
import { FileCard, FileImage } from '~/components/file-view'
import { MarkdownDocument } from '~/components/markdown-document'
import { TableView } from '~/components/table-view'
import type { QueryOutput } from '~/lib/contract.gen'
import { fileHref } from '~/lib/links'
import type { NodeView } from '~/lib/node-view'
import { useObserve } from '~/lib/use-observe'
import { tableSubscription } from '~/sdk/subscriptions'
import type { SpaceContext } from './space'

// Renders the page SpaceBody holds for this address (lib/use-shown-node.ts),
// the same state a send names. The shell has already laid it out: Markdown
// scrolls, HTML is framed or immersive, everything else is framed content.
export default function Node() {
  const { group, client, shown } = useOutletContext<SpaceContext>()
  const { insets } = useShell()
  const view: NodeView = shown?.view ?? { state: 'loading' }
  switch (view.state) {
    case 'loading':
      return null
    case 'error':
      return (
        <div className='wuhu-reader'>
          <p className='wuhu-alert'>{view.message}</p>
        </div>
      )
    case 'markdown':
      return (
        <div className='wuhu-content wuhu-reader'>
          <MarkdownDocument
            client={client}
            path={view.path}
            initial={{ content: view.content, token: view.token }}
            breadcrumb={<Breadcrumb path={view.path} group={group} />}
          />
        </div>
      )
    case 'html':
      return (
        <ContentFrame
          group={group}
          origin={view.origin}
          src={view.src}
          insets={insets}
          remint={client.remintContentSession}
        />
      )
    case 'text':
      return (
        <div className='wuhu-content wuhu-framed'>
          {view.notice && <p className='wuhu-muted'>{view.notice}</p>}
          <pre className='wuhu-text'>{view.content}</pre>
        </div>
      )
    case 'image':
      return (
        <div className='wuhu-content wuhu-framed'>
          <FileImage
            group={group}
            path={view.path}
            size={view.size}
            src={view.src}
            remint={client.remintContentSession}
          />
        </div>
      )
    case 'file':
      return (
        <div className='wuhu-content wuhu-framed'>
          <FileCard path={view.path} size={view.size} src={view.src} />
        </div>
      )
    case 'table':
      return (
        <div className='wuhu-content wuhu-framed'>
          <LiveTable path={view.path} group={group} />
        </div>
      )
  }
}

// Where the document sits: its folders, each a link, then its name.
function Breadcrumb({ path, group }: { path: string; group: string }) {
  const segments = path.split('/').filter(Boolean)
  return (
    <nav className='wuhu-breadcrumb' aria-label='Location'>
      <Link to={fileHref('/', group)}>files</Link>
      {segments.map((segment, index) => (
        <span key={index}>
          <span aria-hidden='true'>/</span>
          {index === segments.length - 1
            ? <span aria-current='page'>{segment}</span>
            : (
              <Link
                to={fileHref(
                  `/${segments.slice(0, index + 1).join('/')}`,
                  group,
                )}
              >
                {segment}
              </Link>
            )}
        </span>
      ))}
    </nav>
  )
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
