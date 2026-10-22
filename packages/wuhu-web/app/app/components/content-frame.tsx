import { useCallback, useEffect, useRef } from 'react'
import { useNavigate } from 'react-router'
import { withGroup } from '~/lib/links'
import type { Insets } from '@wuhu/ui'
import { contentMessage, shellContext } from '~/lib/shell'

// A space page in its sandboxed frame. The shell tells it what its chrome
// covers, again whenever that changes (a growing composer, the sidebar).
export function ContentFrame({
  group,
  origin,
  src,
  insets,
  remint,
}: {
  group: string
  origin: string
  src: string
  insets: Insets
  // Mints a fresh read cookie once the content origin refused the old one.
  remint: () => Promise<unknown>
}) {
  const frame = useRef<HTMLIFrameElement>(null)
  const navigate = useNavigate()
  const { top, left, right, bottom } = insets
  const sendContext = useCallback(() => {
    frame.current?.contentWindow?.postMessage(
      shellContext(globalThis.location.origin, { top, left, right, bottom }),
      origin,
    )
  }, [origin, top, left, right, bottom])

  useEffect(() => {
    const receive = (event: MessageEvent) => {
      if (
        event.origin !== origin ||
        event.source !== frame.current?.contentWindow
      ) {
        return
      }
      const message = contentMessage(event.data)
      if (message?.type === 'wuhu:ready') sendContext()
      if (message?.type === 'wuhu:unauthorized') {
        void remint().then(() => {
          if (frame.current) frame.current.src = src
        }, () => undefined)
      }
      if (message?.type === 'wuhu:navigate') {
        void navigate(withGroup(message.path, group))
      }
    }
    globalThis.addEventListener('message', receive)
    sendContext()
    return () => globalThis.removeEventListener('message', receive)
  }, [group, navigate, origin, remint, sendContext, src])

  return (
    <iframe
      ref={frame}
      src={src}
      title={src}
      sandbox='allow-scripts allow-same-origin allow-forms'
      data-wuhu-content-frame
      onLoad={sendContext}
      className='wuhu-frame'
    />
  )
}
