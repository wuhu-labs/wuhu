import { useMemo } from 'react'
import { useShell } from '@wuhu/ui'
import { HistoryEdge, useOlderIntent } from '~/components/history-edge'
import { Avatar } from '~/components/avatar'
import { stampLabel } from '~/lib/chat'
import { Markdown } from '~/components/markdown-view'
import type { SessionLineEvent } from '~/lib/contract.gen'
import type { SessionRecord } from '~/lib/session-model'
import {
  foldLines,
  hasContent,
  initialLines,
  type LineBlock,
  type LinesState,
  type LineView,
  lineView,
} from '~/lib/transcript-lines'
import { useObserve } from '~/lib/use-observe'
import { useFollowLatest } from '~/lib/use-follow-latest'
import { linesSubscription } from '~/sdk/subscriptions'

export function SessionTranscript({ record }: { record: SessionRecord }) {
  const lines = useObserve<LinesState, SessionLineEvent>(
    linesSubscription(record.id, record.group),
    foldLines,
    initialLines,
  )
  const views = useMemo(
    () => lines.data.lines.map(lineView).filter(hasContent),
    [lines.data],
  )
  const now = new Date()
  const { canvas } = useShell()
  useOlderIntent(canvas, lines.history)
  useFollowLatest(canvas, `${record.id}:${lines.data.generation}`)
  return (
    <section
      className='wuhu-content wuhu-reader wuhu-transcript wuhu-markdown'
      aria-label='Session transcript'
    >
      <h1>Transcript</h1>
      <HistoryEdge edge={lines.history} />
      {views.length === 0 && <p>Nothing yet.</p>}
      {views.map((view) => (
        <article
          key={`line-${view.position}`}
          data-history-id={`line-${view.position}`}
        >
          <header>
            <strong>
              {view.role === 'assistant'
                ? (
                  <>
                    <Avatar
                      principal={record.id}
                      name={record.title}
                      session
                      size={18}
                    />
                    {record.title || record.id}
                  </>
                )
                : lineLabel(view)}
            </strong>
            <time dateTime={view.at.toISOString()}>
              {stampLabel(view.at, now)}
            </time>
          </header>
          {view.rendered !== null && <code>/_/rendered/{view.rendered}</code>}
          {view.blocks.map((block, index) => (
            <LineBlockView
              key={index}
              block={block}
              prose={view.role === 'assistant'}
            />
          ))}
        </article>
      ))}
    </section>
  )
}

const keyLabels: Record<string, string> = {
  system: 'System prompt',
  group: 'Group instructions',
  session: 'Session instructions',
  head: 'Session state',
  'head:note': 'Note',
  'head:summary': 'Conversation summary',
  'head:nudge': 'Compaction notice',
  reestablish: 'Re-established files',
  direct: 'Direct message',
  message: 'Message',
  subscription: 'Notice',
}

function lineLabel(view: LineView): string {
  if (view.role === 'tool_result') {
    return view.failed ? 'Tool result · failed' : 'Tool result'
  }
  return keyLabels[view.key] ?? keyLabels[view.key.split(':')[0]!] ??
    view.key
}

function LineBlockView(
  { block, prose }: { block: LineBlock; prose: boolean },
) {
  switch (block.kind) {
    case 'text':
      return prose
        ? <Markdown>{block.text}</Markdown>
        : <pre className='wuhu-text'>{block.text}</pre>
    case 'reasoning':
      return (
        <details>
          <summary>Reasoning</summary>
          <Markdown>{block.text}</Markdown>
        </details>
      )
    case 'toolCall':
      return (
        <details>
          <summary>{block.name}</summary>
          <pre className='wuhu-text'>{toolArguments(block.arguments)}</pre>
        </details>
      )
    case 'media':
      return <p>Image ({block.mimeType})</p>
    case 'hostedTool':
      return <p>{block.type}</p>
  }
}

function toolArguments(text: string): string {
  try {
    return JSON.stringify(JSON.parse(text), null, 2)
  } catch {
    return text
  }
}
