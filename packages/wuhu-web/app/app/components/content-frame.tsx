import { useCallback, useEffect, useRef } from 'react'
import { useNavigate } from 'react-router'
import { withGroup } from '~/lib/links'
import {
  contentMessage,
  deviceSafeArea,
  shellContext,
  totalInsets,
  zeroInsets,
} from '~/lib/shell'

export function ContentFrame({
  group,
  origin,
  src,
  remint,
}: {
  group: string
  origin: string
  src: string
  // Mints a fresh read cookie once the content origin refused the old one.
  remint: () => Promise<unknown>
}) {
  const frame = useRef<HTMLIFrameElement>(null)
  const navigate = useNavigate()
  const sendContext = useCallback(() => {
    frame.current?.contentWindow?.postMessage(
      shellContext(
        globalThis.location.origin,
        totalInsets(deviceSafeArea(), zeroInsets),
      ),
      origin,
    )
  }, [origin])

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
    globalThis.addEventListener('resize', sendContext)
    globalThis.visualViewport?.addEventListener('resize', sendContext)
    sendContext()
    return () => {
      globalThis.removeEventListener('message', receive)
      globalThis.removeEventListener('resize', sendContext)
      globalThis.visualViewport?.removeEventListener('resize', sendContext)
    }
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
