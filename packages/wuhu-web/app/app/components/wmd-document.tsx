import { Editor } from '@tiptap/core'
import { EditorContent } from '@tiptap/react'
import { EphemeralStore, LoroDoc } from 'loro-crdt/web'
import { type ReactNode, useEffect, useState } from 'react'
import { recoverFromClockRefusal, signedAssertion } from '~/sdk/auth'
import { realTimer } from '~/sdk/observe'
import {
  browserSocket,
  type ChannelState,
  channelStatus,
  liveChannelURL,
  openChannel,
} from '~/lib/wmd/channel'
import {
  type Collab,
  collabExtension,
  importInto,
  type Presence,
  refreshPresence,
} from '~/lib/wmd/collab'
import { configuredDoc, loadLoro } from '~/lib/wmd/loro'
import { wmdExtensions } from '~/lib/wmd/schema'

const presenceTimeoutMs = 30_000

const palette = [
  '#e5484d',
  '#0090ff',
  '#30a46c',
  '#f76b15',
  '#8e4ec6',
  '#d6409f',
  '#12a594',
  '#ad7f58',
]

function colorOf(peer: string): string {
  let hash = 0
  for (const char of peer) hash = (hash * 31 + char.charCodeAt(0)) >>> 0
  return palette[hash % palette.length]
}

interface Live {
  editor: Editor
  collab: Collab
}

// A `.wmd` block document, edited live: every keystroke is a Loro op on the
// document's channel, and the other people in it show as named cursors.
// `create` asks the server to create the document, which is missing.
export default function WmdDocument({
  path,
  group,
  frameOrigin,
  create,
  breadcrumb,
}: {
  path: string
  group: string
  frameOrigin: string | null
  create: boolean
  breadcrumb: ReactNode
}) {
  const [live, setLive] = useState<Live | null>(null)
  const [channel, setChannel] = useState<ChannelState>({
    phase: 'connecting',
    editable: false,
    lostEdits: false,
  })
  const [welcomed, setWelcomed] = useState(false)
  const [failure, setFailure] = useState<string | null>(null)

  useEffect(() => {
    let disposed = false
    let teardown = () => {}
    loadLoro().then(() => {
      if (disposed) return
      const doc = configuredDoc(new LoroDoc())
      const presence = new EphemeralStore<Record<string, Presence>>(
        presenceTimeoutMs,
      )
      let identity: { name: string; color: string } | null = null
      let clock: number | null = null
      const collab: Collab = {
        doc,
        presence,
        self: doc.peerIdStr,
        identity: () => identity,
      }
      const editor = new Editor({
        extensions: [
          ...wmdExtensions({
            src: (view) =>
              frameOrigin == null
                ? null
                : `${frameOrigin}/_/views/${
                  encodeURIComponent(view.view)
                }?${new URLSearchParams({ def: JSON.stringify(view) })}`,
          }),
          collabExtension(collab),
        ],
        editable: false,
        editorProps: {
          attributes: {
            class: 'wuhu-markdown wuhu-editor wmd-editor',
            spellcheck: 'false',
          },
        },
      })
      const close = openChannel({
        url: liveChannelURL(path, globalThis.location),
        group,
        doc,
        presence,
        create,
        assertion: async (afterRefusal) => {
          if (afterRefusal) await recoverFromClockRefusal(clock)
          const signed = await signedAssertion()
          clock = signed?.clock ?? null
          return signed?.assertion ?? null
        },
        importing: (change) => importInto(editor.view, doc, change),
        open: browserSocket,
        timer: realTimer,
        changed: (state) => {
          setChannel(state)
          if (state.phase === 'live' || state.phase === 'syncing') {
            setWelcomed(true)
            const color = colorOf(doc.peerIdStr)
            if (identity?.name !== state.name) {
              identity = { name: state.name, color }
              refreshPresence(editor.view, collab)
            }
          }
          editor.setEditable(state.editable, false)
        },
      })
      setLive({ editor, collab })
      teardown = () => {
        close()
        editor.destroy()
        presence.destroy()
        doc.free()
      }
    }, (error: unknown) => {
      if (!disposed) setFailure(String(error))
    })
    return () => {
      disposed = true
      teardown()
      setLive(null)
      setWelcomed(false)
    }
    // Only the first hello reads `create`: the open channel outlives the path
    // turning from missing to present.
  }, [path, group, frameOrigin])

  return (
    <section className='wuhu-document' data-wuhu-document={path}>
      <div className='wuhu-document-utility'>
        {breadcrumb}
        <span className='wmd-status' data-phase={channel.phase}>
          {channelStatus(channel)}
        </span>
      </div>
      {failure != null && <p className='wuhu-alert' role='alert'>{failure}</p>}
      {channel.phase === 'refused' && (
        <p className='wuhu-alert' role='alert'>{channel.message}</p>
      )}
      {channel.lostEdits && (
        <p className='wuhu-alert' role='alert'>
          Your recent edits were not saved; copy them elsewhere before leaving.
        </p>
      )}
      {channel.phase === 'live' && channel.peers.length > 1 && (
        <div className='wmd-peers' aria-label='People here'>
          {channel.peers.map((peer) => (
            <span key={peer.connection} className='wmd-peer'>
              {peer.name}
            </span>
          ))}
        </div>
      )}
      {live != null && welcomed && (
        <div
          className='wuhu-editor-frame'
          data-editable={live.editor.isEditable}
        >
          <EditorContent editor={live.editor} />
        </div>
      )}
    </section>
  )
}
