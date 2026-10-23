import { useMemo } from 'react'
import { useShell } from '@wuhu/ui'
import { HistoryEdge, useOlderIntent } from '~/components/history-edge'
import { Avatar } from '~/components/avatar'
import { stampLabel } from '~/lib/chat'
import { senderIsSession, senderName } from '~/lib/directory'
import { Attachments } from '~/components/attachments'
import { crossOriginFor } from '~/lib/groups'
import {
  useDirectory,
  useGroupOrigin,
  useSessionTitles,
} from '~/lib/use-directory'
import { Markdown } from '~/components/markdown-view'
import type { SessionStreamEvent } from '~/lib/contract.gen'
import type { SessionRecord } from '~/lib/session-model'
import {
  type DirectState,
  foldDirect,
  initialDirectState,
} from '~/lib/transcript-fold'
import { useObserve } from '~/lib/use-observe'
import { useFollowLatest } from '~/lib/use-follow-latest'
import { eventKey, type WorkEvent, workEvents } from '~/lib/work-events'
import { directSubscription } from '~/sdk/subscriptions'

export function SessionTranscript({ record }: { record: SessionRecord }) {
  const origin = useGroupOrigin(record.group)
  const direct = useObserve<DirectState, SessionStreamEvent>(
    directSubscription(record.id, record.group),
    foldDirect,
    initialDirectState,
  )
  const events = useMemo(
    () => workEvents(direct.data).filter(hasContent),
    [direct.data],
  )
  const now = new Date()
  const { canvas } = useShell()
  useOlderIntent(canvas, direct.history)
  useFollowLatest(
    canvas,
    `${record.id}:${direct.data.generation}:${
      direct.history?.historyEpoch ?? ''
    }`,
  )
  return (
    <section
      className='wuhu-content wuhu-reader wuhu-transcript wuhu-markdown'
      aria-label='Session transcript'
    >
      <h1>Transcript</h1>
      <HistoryEdge edge={direct.history} />
      {events.length === 0 && <p>Nothing yet.</p>}
      {events.map((event) => (
        <article key={eventKey(event.id)} data-history-id={eventKey(event.id)}>
          <header>
            <strong>
              {event.kind === 'input'
                ? <TranscriptSender input={event.input} />
                : event.kind === 'assistantText' || event.kind === 'reasoning'
                ? (
                  <>
                    <Avatar
                      principal={record.id}
                      name={record.title}
                      session
                      size={18}
                    />
                    {record.title || record.id}
                    {event.kind === 'reasoning'
                      ? ' · reasoning'
                      : event.streaming
                      ? ' · writing'
                      : ''}
                  </>
                )
                : eventLabel(event)}
            </strong>
            {event.timestamp && (
              <time dateTime={event.timestamp.toISOString()}>
                {stampLabel(event.timestamp, now)}
              </time>
            )}
          </header>
          {event.kind === 'input' && (
            <Attachments
              attachments={event.input.attachments}
              origin={origin}
              crossOrigin={crossOriginFor(record.group)}
            />
          )}
          <TranscriptBody event={event} />
        </article>
      ))}
    </section>
  )
}

function TranscriptSender(
  { input }: { input: Extract<WorkEvent, { kind: 'input' }>['input'] },
) {
  const directory = useDirectory()
  const sessions = useSessionTitles()
  const message = {
    sender: input.senderSession ?? input.sender,
    senderKind: input.senderSession == null ? undefined : 'session',
  }
  const fromSession = senderIsSession(sessions, message)
  const name = senderName(directory, message, sessions)
  return (
    <>
      <Avatar
        principal={message.sender}
        name={fromSession ? name : undefined}
        session={fromSession}
        size={18}
      />
      {name}
    </>
  )
}

const noticeLabels: Record<string, string> = {
  timer: 'Timer',
  spaceObservation: 'Observation',
  compactRequest: 'Compaction request',
  owedReply: 'Reply reminder',
  parkReminder: 'Park reminder',
  childFailed: 'Child session failed',
  requestDeadline: 'Request deadline',
  requestStall: 'Request stalled',
  script: 'Script',
  exec: 'Command',
  context: 'Context',
}

function hasContent(event: WorkEvent): boolean {
  switch (event.kind) {
    case 'input':
      return event.input.text.trim() !== '' ||
        event.input.attachments.length > 0
    case 'notification':
      return event.notice.text.trim() !== ''
    case 'assistantText':
      return event.text.trim() !== ''
    case 'reasoning':
      return event.summary.trim() !== ''
    case 'generationHead':
      return event.head.summary.trim() !== '' ||
        (event.head.note ?? '').trim() !== ''
    case 'toolResult':
      return event.result.output != null &&
        (typeof event.result.output !== 'string' ||
          event.result.output.trim() !== '')
    case 'toolCall':
    case 'bookmark':
      return true
  }
}

function eventLabel(event: WorkEvent): string {
  switch (event.kind) {
    case 'input':
      return event.input.kind === 'message' ? 'Message' : 'Input'
    case 'notification':
      return noticeLabels[event.notice.kind] ?? event.notice.kind
        .replace(/([a-z])([A-Z])/g, '$1 $2')
        .replace(/[_-]/g, ' ')
        .replace(/^./, (letter) => letter.toUpperCase())
    case 'assistantText':
      return event.streaming ? 'Assistant · writing' : 'Assistant'
    case 'reasoning':
      return 'Reasoning'
    case 'toolCall':
      return event.call.name
    case 'toolResult':
      return event.result.failed ? 'Tool result · failed' : 'Tool result'
    case 'bookmark':
      return 'Bookmark'
    case 'generationHead':
      return 'Generation summary'
  }
}

function TranscriptBody({ event }: { event: WorkEvent }) {
  switch (event.kind) {
    case 'input':
      return <Markdown>{event.input.text}</Markdown>
    case 'notification':
      return <Markdown>{event.notice.text}</Markdown>
    case 'assistantText':
      return <Markdown>{event.text}</Markdown>
    case 'reasoning':
      return (
        <details>
          <summary>Show reasoning</summary>
          <Markdown>{event.summary}</Markdown>
        </details>
      )
    case 'toolCall':
      return (
        <details>
          <summary>Arguments</summary>
          <pre className='wuhu-text'>
            {toolText(event.call.arguments)}
          </pre>
        </details>
      )
    case 'toolResult':
      return (
        <details>
          <summary>Output</summary>
          <pre className='wuhu-text'>
            {toolText(event.result.output)}
          </pre>
        </details>
      )
    case 'bookmark':
      return <p>{event.name ?? 'Unnamed bookmark'}</p>
    case 'generationHead':
      return (
        <>
          <Markdown>{event.head.summary}</Markdown>
          {event.head.note && <p>{event.head.note}</p>}
        </>
      )
  }
}

function toolText(value: unknown): string | undefined {
  return typeof value === 'string' ? value : JSON.stringify(value, null, 2)
}
