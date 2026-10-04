import { useEffect, useRef } from 'react'
import { OlderIntent } from '~/lib/history-intent'
import type { HistoryEdge as Edge } from '~/sdk/paged-observe'

export function useOlderIntent(
  canvas: HTMLElement | null,
  edge: Edge | undefined,
) {
  const current = useRef(edge)
  current.current = edge
  useEffect(() => {
    if (!canvas) return
    const intent = new OlderIntent()
    let frame = 0
    const approach = () => {
      if (
        intent.approach(canvas.scrollTop, current.current?.status === 'ready')
      ) current.current?.loadOlder()
    }
    const afterMovement = () => {
      cancelAnimationFrame(frame)
      frame = requestAnimationFrame(approach)
    }
    const moved = () => intent.moved(canvas.scrollTop)
    const wheel = (event: WheelEvent) => {
      if (event.deltaY < 0) {
        intent.wheel(performance.now())
        approach()
        afterMovement()
      }
    }
    const key = (event: KeyboardEvent) => {
      const target = event.target as HTMLElement
      if (target.closest('input,textarea,[contenteditable=true]')) return
      if (!event.repeat && ['ArrowUp', 'PageUp', 'Home'].includes(event.key)) {
        intent.begin()
        approach()
        afterMovement()
      }
    }
    let touchY: number | null = null
    const touchStart = (event: TouchEvent) => {
      intent.begin()
      touchY = event.touches[0]?.clientY ?? null
    }
    const touchMove = (event: TouchEvent) => {
      const y = event.touches[0]?.clientY ?? null
      if (y !== null && touchY !== null && y > touchY) {
        approach()
        afterMovement()
      }
      touchY = y
    }
    canvas.addEventListener('scroll', moved, { passive: true })
    canvas.addEventListener('wheel', wheel, { passive: true })
    canvas.addEventListener('keydown', key)
    canvas.addEventListener('touchstart', touchStart, { passive: true })
    canvas.addEventListener('touchmove', touchMove, { passive: true })
    return () => {
      cancelAnimationFrame(frame)
      canvas.removeEventListener('scroll', moved)
      canvas.removeEventListener('wheel', wheel)
      canvas.removeEventListener('keydown', key)
      canvas.removeEventListener('touchstart', touchStart)
      canvas.removeEventListener('touchmove', touchMove)
    }
  }, [canvas])
}

export function HistoryEdge({ edge }: { edge: Edge | undefined }) {
  if (!edge) return null
  return (
    <div
      className='wuhu-history-edge'
      aria-busy={edge.status === 'loading' || edge.status === 'preparing'}
    >
      {edge.status === 'loading'
        ? <span role='status'>Loading…</span>
        : edge.status === 'preparing'
        ? <span role='status'>Preparing history…</span>
        : edge.status === 'error'
        ? (
          <>
            <span role='status'>{edge.error}</span>
            <button
              type='button'
              className='wuhu-quiet-button'
              onClick={edge.retry}
            >
              Retry loading history
            </button>
          </>
        )
        : edge.hasEarlier
        ? (
          <button
            type='button'
            className='wuhu-quiet-button'
            onClick={edge.loadOlder}
          >
            {edge.gap ? '↑ Load missing history' : '↑ Load older'}
          </button>
        )
        : <span>Beginning of history</span>}
    </div>
  )
}
