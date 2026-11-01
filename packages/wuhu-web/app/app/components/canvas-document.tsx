import { EphemeralStore, LoroDoc, UndoManager } from 'loro-crdt/web'
import { useEffect, useMemo, useState } from 'react'
import { CanvasEditing } from '~/components/canvas-editing'
import { CanvasView } from '~/components/canvas-view'
import { type Board, boardOf, configuredBoard } from '~/lib/canvas/board'
import { sceneOf } from '~/lib/canvas/scene'
import {
  browserSocket,
  type ChannelState,
  channelStatus,
  liveChannelURL,
  openChannel,
} from '~/lib/wmd/channel'
import type { Presence } from '~/lib/wmd/collab'
import { loadLoro } from '~/lib/wmd/loro'
import { recoverFromClockRefusal, signedAssertion } from '~/sdk/auth'
import { realTimer } from '~/sdk/observe'

const presenceTimeoutMs = 30_000

interface Live {
  doc: LoroDoc
  undo: UndoManager
  board: Board
}

// A live `.canvas` board: its Loro doc follows the document's channel, and
// every change, ours or imported, redraws on the next frame. The view mounts
// once the first sync lands, so its camera fits the real board; a channel that
// grants write mounts the editor instead.
export default function CanvasDocument({ path, group, frameOrigin, find }: {
  path: string
  group: string
  frameOrigin: string | null
  find(glob: string, limit: number): Promise<string[]>
}) {
  const [live, setLive] = useState<Live | null>(null)
  const [channel, setChannel] = useState<ChannelState>({
    phase: 'connecting',
    editable: false,
    lostEdits: false,
  })
  const [failure, setFailure] = useState<string | null>(null)

  useEffect(() => {
    let disposed = false
    let teardown = () => {}
    loadLoro().then(() => {
      if (disposed) return
      const doc = configuredBoard(new LoroDoc())
      const undo = new UndoManager(doc, { mergeInterval: 0 })
      const presence = new EphemeralStore<Record<string, Presence>>(
        presenceTimeoutMs,
      )
      let synced = false
      let frame: number | null = null
      const redraw = () => {
        if (!synced) return
        frame ??= requestAnimationFrame(() => {
          frame = null
          setLive({ doc, undo, board: boardOf(doc) })
        })
      }
      const stopChanges = doc.subscribe(redraw)
      let clock: number | null = null
      const close = openChannel({
        url: liveChannelURL(path, globalThis.location),
        group,
        doc,
        presence,
        create: false,
        assertion: async (afterRefusal) => {
          if (afterRefusal) await recoverFromClockRefusal(clock)
          const signed = await signedAssertion()
          clock = signed?.clock ?? null
          return signed?.assertion ?? null
        },
        importing: (change) => change(),
        open: browserSocket,
        timer: realTimer,
        changed: (state) => {
          setChannel(state)
          if (state.phase === 'live' && !synced) {
            synced = true
            redraw()
          }
        },
      })
      teardown = () => {
        close()
        stopChanges()
        if (frame !== null) cancelAnimationFrame(frame)
        presence.destroy()
        undo.free()
        doc.free()
      }
    }, (error: unknown) => {
      if (!disposed) setFailure(String(error))
    })
    return () => {
      disposed = true
      teardown()
      setLive(null)
    }
  }, [path, group])

  const imageSrc = (image: string) =>
    frameOrigin == null ? null : frameOrigin + encodeURI(image)
  const board = live?.board
  const scene = useMemo(() => board && sceneOf(board), [board])
  return (
    <section className='canvas-document' data-wuhu-document={path}>
      {live != null && channel.editable && (
        <CanvasEditing
          doc={live.doc}
          board={live.board}
          undo={live.undo}
          imageSrc={imageSrc}
          find={find}
        />
      )}
      {scene != null && !channel.editable && (
        <CanvasView scene={scene} imageSrc={imageSrc} />
      )}
      <div className='canvas-document-status'>
        <span className='wmd-status' data-phase={channel.phase}>
          {channelStatus(channel)}
        </span>
        {failure != null && <p className='wuhu-alert' role='alert'>{failure}
        </p>}
        {channel.phase === 'refused' && (
          <p className='wuhu-alert' role='alert'>{channel.message}</p>
        )}
      </div>
    </section>
  )
}
