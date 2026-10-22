import { useEffect, useLayoutEffect, useRef } from 'react'
import {
  type Follow,
  followAfterScroll,
  scrollAfterResize,
} from './timeline-follow.ts'

// Keeps the scroller on the latest message while the reader is there,
// whatever grows it: a new message, an image that finishes loading, a taller
// composer or a shorter window. Away from the bottom, the first row on screen
// stays put while older history arrives above it.
export function useFollowLatest(canvas: HTMLElement | null, identity?: string) {
  const follow = useRef<Follow>({ following: true, scrollTop: 0 })
  const anchor = useRef<{ id: string; top: number } | null>(null)

  const rows = (scroller: HTMLElement) => [
    ...scroller.querySelectorAll('[data-history-id]'),
  ]

  // Older history landing above keeps the anchored row where it was.
  useLayoutEffect(() => {
    const held = anchor.current
    if (canvas === null || held === null || follow.current.following) return
    const element = rows(canvas).find((row) =>
      row.getAttribute('data-history-id') === held.id
    )
    if (element === undefined) return
    canvas.scrollTop += element.getBoundingClientRect().top - held.top
    follow.current = { following: false, scrollTop: canvas.scrollTop }
  })

  useEffect(() => {
    if (canvas === null) return
    const remember = () => {
      const top = canvas.getBoundingClientRect().top
      const element = rows(canvas).find((row) =>
        row.getBoundingClientRect().bottom > top
      )
      anchor.current = element === undefined ? null : {
        id: element.getAttribute('data-history-id')!,
        top: element.getBoundingClientRect().top,
      }
    }
    const onScroll = () => {
      follow.current = followAfterScroll(follow.current, canvas)
      if (follow.current.following) anchor.current = null
      else remember()
    }
    const observer = new ResizeObserver(() => {
      const scrollTop = scrollAfterResize(follow.current, canvas)
      if (scrollTop === null) return
      canvas.scrollTop = scrollTop
      follow.current = { following: true, scrollTop: canvas.scrollTop }
    })
    observer.observe(canvas)
    if (canvas.firstElementChild) observer.observe(canvas.firstElementChild)
    canvas.addEventListener('scroll', onScroll, { passive: true })
    anchor.current = null
    canvas.scrollTop = canvas.scrollHeight
    follow.current = { following: true, scrollTop: canvas.scrollTop }
    return () => {
      observer.disconnect()
      canvas.removeEventListener('scroll', onScroll)
    }
  }, [canvas, identity])
}
