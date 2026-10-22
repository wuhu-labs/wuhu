import type { ReactNode } from 'react'
import { useShell } from '@wuhu/ui'
import { HistoryEdge, useOlderIntent } from '~/components/history-edge'
import { type ChatEntry, chatItems, stampLabel } from '~/lib/chat'
import { useFollowLatest } from '~/lib/use-follow-latest'
import type { HistoryEdge as Edge } from '~/sdk/paged-observe'

export interface ChatMessage extends ChatEntry {
  body: ReactNode
}

// One chat page, sessions and channels alike: Messages-style runs of bubbles,
// mine on the right in black, everyone else's mirrored on the left. A named
// run carries the sender's name above it; its photo stands beside the run's
// last bubble (a channel's strip) or inline before the name (a box, whose
// left bubbles keep one edge).
export function ChatView({
  messages,
  history,
  identity,
  sender,
  avatars = 'strip',
  empty,
}: {
  messages: readonly ChatMessage[]
  history?: Edge
  // Changes when the stream starts over, so the view pins to the latest again.
  identity?: string
  // Who a run is from, or null for a run that needs no name.
  sender?: (id: string) => { name: string; avatar: ReactNode } | null
  avatars?: 'strip' | 'inline'
  empty?: string
}) {
  const { canvas } = useShell()
  useFollowLatest(canvas, identity)
  useOlderIntent(canvas, history)
  const now = new Date()
  return (
    <div className='wuhu-chat'>
      <HistoryEdge edge={history} />
      {messages.length === 0 && empty && (
        <p className='wuhu-chat-empty'>{empty}</p>
      )}
      {chatItems(messages).map((item) => {
        if (item.kind === 'stamp') {
          return (
            <time
              key={item.key}
              className='wuhu-stamp'
              dateTime={item.at.toISOString()}
            >
              {stampLabel(item.at, now)}
            </time>
          )
        }
        const from = item.own ? null : sender?.(item.sender) ?? null
        const last = item.entries.at(-1)!
        return (
          <div
            key={item.key}
            className='wuhu-run'
            data-own={item.own || undefined}
            data-named={from ? avatars : undefined}
          >
            {from && (
              <div className='wuhu-run-name'>
                {avatars === 'inline' && from.avatar}
                {from.name}
              </div>
            )}
            {item.entries.map((entry) => (
              <div
                key={entry.key}
                className='wuhu-run-line'
                data-history-id={entry.key}
              >
                {from && avatars === 'strip' && (
                  <span className='wuhu-run-avatar'>
                    {entry === last && from.avatar}
                  </span>
                )}
                <div
                  className='wuhu-bubble'
                  data-tail={entry === last || undefined}
                >
                  {entry.body}
                </div>
              </div>
            ))}
          </div>
        )
      })}
    </div>
  )
}
