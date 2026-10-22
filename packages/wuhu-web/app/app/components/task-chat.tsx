import { useMemo } from 'react'
import { type ChatMessage, ChatView } from '~/components/chat-view'
import { Markdown } from '~/components/markdown-view'
import type { SessionStreamEvent } from '~/lib/contract.gen'
import type { SessionRecord } from '~/lib/session-model'
import { taskLines } from '~/lib/task-lines'
import {
  type DirectState,
  foldDirect,
  initialDirectState,
} from '~/lib/transcript-fold'
import { useObserve } from '~/lib/use-observe'
import { workEvents } from '~/lib/work-events'
import { directSubscription } from '~/sdk/subscriptions'

// A task opens as a chat page with no composer: what it was handed on the
// right, what it said back on the left. Tool turns are not drawn.
export function TaskChat({ record }: { record: SessionRecord }) {
  const direct = useObserve<DirectState, SessionStreamEvent>(
    directSubscription(record.id, record.group),
    foldDirect,
    initialDirectState,
  )
  const state = direct.data
  const messages = useMemo(
    () =>
      taskLines(workEvents(state)).map((line): ChatMessage => ({
        ...line,
        body: (
          <div className='wuhu-markdown'>
            <Markdown>{line.text}</Markdown>
          </div>
        ),
      })),
    [state],
  )
  return (
    <ChatView
      messages={messages}
      history={direct.history}
      identity={`${state.generation}:${direct.history?.historyEpoch ?? ''}`}
      empty='Nothing yet.'
    />
  )
}
