import { useLocation, useOutletContext } from 'react-router'
import { useDocument } from '~/components/session-context-chain'
import { MarkdownView } from '~/components/markdown-view'
import { systemAddress } from '~/lib/links'
import type { SpaceClient } from '~/sdk/client'
import type { SpaceContext } from './space'

export function meta() {
  return [{ title: 'System · Wuhu' }]
}

export default function System() {
  const address = systemAddress(useLocation().pathname)
  const { client } = useOutletContext<SpaceContext>()
  return (
    <div className='wuhu-content wuhu-page'>
      {address == null
        ? <p className='wuhu-alert'>Nothing lives at this address.</p>
        : <SystemFile client={client} address={address} />}
    </div>
  )
}

function SystemFile(
  { client, address }: { client: SpaceClient; address: string },
) {
  const [load] = useDocument(client, address)
  return (
    <>
      <header className='wuhu-context-section wuhu-system-head'>
        <span className='wuhu-context-path'>{address}</span>
        <p className='wuhu-muted'>
          Built into the server and the same in every space. Read-only.
        </p>
      </header>
      {load.state === 'loading' && <p className='wuhu-muted'>Loading…</p>}
      {load.state === 'error' && <p className='wuhu-alert'>{load.message}</p>}
      {load.state === 'missing' && (
        <p className='wuhu-muted'>This server has no such system file.</p>
      )}
      {load.state === 'ready' && (
        /\.(md|markdown)$/.test(address)
          ? <MarkdownView content={load.read.content} />
          : <pre className='wuhu-text'>{load.read.content}</pre>
      )}
    </>
  )
}
