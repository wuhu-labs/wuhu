import { useEffect, useRef, useState } from 'react'
import { foldMessage, type MessageMap } from './conversation.ts'
import { latestOrdinal, ReadMark } from './read-mark.ts'
import { useObserve } from './use-observe.ts'
import type { ConversationMessagePayload } from './contract.gen.ts'
import type { Liveness } from '~/sdk/observe'
import type { HistoryEdge } from '~/sdk/paged-observe'
import { markConversationRead } from '~/sdk/conversation'
import { conversationSubscription } from '~/sdk/subscriptions'

// A conversation is read while its tab is visible and its window has focus.
function isReading(): boolean {
  return typeof document === 'undefined' ||
    (document.visibilityState === 'visible' && document.hasFocus())
}

function usePageReading(): boolean {
  const [reading, setReading] = useState(isReading)
  useEffect(() => {
    const onChange = () => setReading(isReading())
    document.addEventListener('visibilitychange', onChange)
    globalThis.addEventListener('focus', onChange)
    globalThis.addEventListener('blur', onChange)
    return () => {
      document.removeEventListener('visibilitychange', onChange)
      globalThis.removeEventListener('focus', onChange)
      globalThis.removeEventListener('blur', onChange)
    }
  }, [])
  return reading
}

// Observes one conversation and marks it read while it is on screen.
export function useConversation(
  conversationId: string,
  group: string,
): { messages: MessageMap; liveness: Liveness; history?: HistoryEdge } {
  const conversation = useObserve<MessageMap, ConversationMessagePayload>(
    conversationSubscription(conversationId, group),
    foldMessage,
    new Map(),
  )
  const latest = latestOrdinal(conversation.data)
  const reading = usePageReading()
  const mark = useRef(new ReadMark())
  useEffect(() => {
    if (
      !mark.current.advance(latest, reading, conversation.liveness === 'live')
    ) {
      return
    }
    markConversationRead(conversationId, group).catch(() => {})
  }, [conversationId, group, latest, reading, conversation.liveness])
  return {
    messages: conversation.data,
    liveness: conversation.liveness,
    history: conversation.history,
  }
}
