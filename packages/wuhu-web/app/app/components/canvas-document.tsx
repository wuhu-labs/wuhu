import { EphemeralStore, LoroDoc } from 'loro-crdt/web'
import { useEffect, useState } from 'react'
import { CanvasView } from '~/components/canvas-view'
import { boardOf } from '~/lib/canvas/board'
import { type CanvasScene, sceneOf } from '~/lib/canvas/scene'
import {
  browserSocket,
  type ChannelState,
  channelStatus,
  liveChannelURL,
  openChannel,
} from '~/lib/wmd/channel'
import type { Presence } from '~/lib/wmd/collab'
import { configuredDoc, loadLoro } from '~/lib/wmd/loro'
import { recoverFromClockRefusal, signedAssertion } from '~/sdk/auth'
import { realTimer } from '~/sdk/observe'

const presenceTimeoutMs = 30_000

// A `.canvas` board, view-only and live: its Loro doc follows the document's
// channel, and each import redraws the scene on the next frame. The view
// mounts once the first sync lands, so its camera fits the real board.
export default function CanvasDocument({ path, group, frameOrigin }: {
  path: string
  group: string
  frameOrigin: string | null
}) {
  const [scene, setScene] = useState<CanvasScene | null>(null)
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
      const doc = configuredDoc(new LoroDoc())
      const presence = new EphemeralStore<Record<string, Presence>>(
        presenceTimeoutMs,
      )
      let synced = false
      let frame: number | null = null
      const redraw = () => {
        if (!synced) return
        frame ??= requestAnimationFrame(() => {
          frame = null
          setScene(sceneOf(boardOf(doc)))
        })
      }
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
        importing: (change) => {
          change()
          redraw()
        },
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
        if (frame !== null) cancelAnimationFrame(frame)
        presence.destroy()
        doc.free()
      }
    }, (error: unknown) => {
      if (!disposed) setFailure(String(error))
    })
    return () => {
      disposed = true
      teardown()
      setScene(null)
    }
  }, [path, group])

  const imageSrc = (image: string) =>
    frameOrigin == null ? null : frameOrigin + encodeURI(image)
  return (
    <section className='canvas-document' data-wuhu-document={path}>
      {scene != null && <CanvasView scene={scene} imageSrc={imageSrc} />}
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
