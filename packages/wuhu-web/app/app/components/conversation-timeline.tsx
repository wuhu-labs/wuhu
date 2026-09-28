import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
} from 'react'
import { useChrome } from '@wuhu/ui'
import { MessageRow } from '~/components/message-row'
import { useOwnPrincipal } from '~/lib/use-directory'
import {
  type MessageMap,
  orderedMessages,
  ownerOf,
  type ReplyDraft,
} from '~/lib/conversation'
import {
  type Follow,
  followAfterScroll,
  holdAnchor,
  scrollAfterResize,
} from '~/lib/timeline-follow'

// Keeps the canvas on the latest message while the reader is there, whatever
// grows it: a new message, an image that finishes loading, a taller composer
// or a shorter window. `hold` keeps an element in place across the next
// render instead, for a change the reader made above the latest.
export function useFollowLatest(canvas: HTMLElement | null) {
  const follow = useRef<Follow>({ following: true, scrollTop: 0 })
  const anchor = useRef<{ element: Element; top: number } | null>(null)
  const [following, setFollowing] = useState(true)

  const hold = useCallback((element: Element) => {
    anchor.current = { element, top: element.getBoundingClientRect().top }
    follow.current = { ...follow.current, following: false }
    setFollowing(false)
  }, [])

  useLayoutEffect(() => {
    const held = anchor.current
    if (canvas === null || held === null) return
    anchor.current = null
    follow.current = holdAnchor(
      canvas.scrollTop,
      held.top,
      held.element.getBoundingClientRect().top,
    )
    canvas.scrollTop = follow.current.scrollTop
  })

  const pin = useCallback(() => {
    if (canvas === null) return
    canvas.scrollTop = canvas.scrollHeight
    follow.current = { following: true, scrollTop: canvas.scrollTop }
    setFollowing(true)
  }, [canvas])

  useEffect(() => {
    if (canvas === null) return
    const onScroll = () => {
      follow.current = followAfterScroll(follow.current, canvas)
      setFollowing(follow.current.following)
    }
    const observer = new ResizeObserver(() => {
      const scrollTop = scrollAfterResize(follow.current, canvas)
      if (scrollTop === null) return
      canvas.scrollTop = scrollTop
      follow.current = { following: true, scrollTop: canvas.scrollTop }
    })
    observer.observe(canvas)
    observer.observe(canvas.firstElementChild!, { box: 'border-box' })
    canvas.addEventListener('scroll', onScroll, { passive: true })
    pin()
    return () => {
      observer.disconnect()
      canvas.removeEventListener('scroll', onScroll)
    }
  }, [canvas, pin])

  return { following, pin, hold }
}

export function ConversationTimeline({
  messages,
  group,
  onReply,
}: {
  messages: MessageMap
  group: string
  onReply?: (draft: ReplyDraft) => void
}) {
  const { canvas } = useChrome()
  const { following, pin } = useFollowLatest(canvas)
  const owns = ownerOf(useOwnPrincipal())
  const ordered = orderedMessages(messages)
  // Nothing is drawn until sides are known, so no message moves once shown.
  if (owns === null) return <p className='wuhu-muted'>Loading…</p>
  return (
    <>
      {ordered.length === 0 && <p className='wuhu-muted'>No messages yet.</p>}
      <div className='wuhu-message-list'>
        {ordered.map((message) => (
          <MessageRow
            key={message.messageId}
            message={message}
            messages={messages}
            group={group}
            own={owns(message.sender)}
            onReply={onReply}
          />
        ))}
      </div>
      {!following && ordered.length > 0 && (
        <button
          type='button'
          aria-label='Jump to latest'
          className='wuhu-jump'
          onClick={pin}
        >
          ↓ latest
        </button>
      )}
    </>
  )
}
