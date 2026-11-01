import { lazy, Suspense, useState } from 'react'
import { Link, useOutletContext } from 'react-router'
import { useShell } from '@wuhu/ui'
import { ContentFrame } from '~/components/content-frame'
import { FileCard, FileImage } from '~/components/file-view'
import { MarkdownDocument } from '~/components/markdown-document'
import { TableView } from '~/components/table-view'
import type { QueryOutput } from '~/lib/contract.gen'
import { fileHref } from '~/lib/links'
import type { NodeView } from '~/lib/node-view'
import { contentOriginString } from '~/lib/use-content-origin'
import { useObserve } from '~/lib/use-observe'
import { tableSubscription } from '~/sdk/subscriptions'
import type { SpaceContext } from './space'

const WmdDocument = lazy(() => import('~/components/wmd-document'))
const CanvasDocument = lazy(() => import('~/components/canvas-document'))

// Renders the page SpaceBody holds for this address (lib/use-shown-node.ts),
// the same state a send names. The shell has already laid it out: Markdown
// scrolls, HTML is framed or immersive, everything else is framed content.
export default function Node() {
  const { group, client, shown, contentOrigin } = useOutletContext<
    SpaceContext
  >()
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
    case 'wmd':
    case 'missingWmd':
      return (
        <div className='wuhu-content wuhu-reader'>
          {contentOrigin !== undefined && (
            <WmdPage
              key={view.path}
              path={view.path}
              group={group}
              frameOrigin={contentOriginString(contentOrigin)}
              missing={view.state === 'missingWmd' ? view.message : null}
            />
          )}
        </div>
      )
    case 'canvas':
      return (
        <div className='wuhu-content canvas-page'>
          {contentOrigin !== undefined && (
            <Suspense fallback={null}>
              <CanvasDocument
                key={view.path}
                path={view.path}
                group={group}
                frameOrigin={contentOriginString(contentOrigin)}
              />
            </Suspense>
          )}
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

// A missing document opens only on Create, which asks its channel to create
// it; once the path exists the page goes on as an ordinary `.wmd` page.
function WmdPage({ path, group, frameOrigin, missing }: {
  path: string
  group: string
  frameOrigin: string | null
  missing: string | null
}) {
  const [creating, setCreating] = useState(false)
  if (missing != null && !creating) {
    return (
      <>
        <p className='wuhu-alert'>{missing}</p>
        <button
          type='button'
          className='wuhu-button'
          onClick={() => setCreating(true)}
        >
          Create
        </button>
      </>
    )
  }
  return (
    <Suspense>
      <WmdDocument
        path={path}
        group={group}
        frameOrigin={frameOrigin}
        create={missing != null}
        breadcrumb={<Breadcrumb path={path} group={group} />}
      />
    </Suspense>
  )
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
