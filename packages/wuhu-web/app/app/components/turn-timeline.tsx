import { memo } from 'react'
import { Icon, type IconName } from '@wuhu/ui'
import { Attachments } from '~/components/attachments'
import { CopyButton } from '~/components/copy-button'
import { Markdown } from '~/components/markdown-view'
import {
  type Names,
  preview,
  sendTarget,
  summaryText,
  toolStateLabel,
  wakeLabel,
  wakeTime,
} from '~/lib/turn-labels'
import type { Destination } from '~/lib/turn-inspection'
import {
  baseName,
  rowAnchors,
  type ToolActivity,
  toolState,
  toolSubject,
  type TurnProjection,
  type Wake,
  wakeText,
  type WorkItem,
} from '~/lib/turns'
import { useGroupOrigin } from '~/lib/use-directory'
import { crossOriginFor } from '~/lib/groups'

interface Actions {
  // The session's group, whose content origin holds what its wakes attach.
  group: string
  names: Names
  inspect: (destination: Destination) => void
}

const Block = memo(function Block({ source }: { source: string }) {
  return <Markdown>{source}</Markdown>
})

function splitBlocks(text: string): string[] {
  const blocks: string[] = []
  let current: string[] = []
  let fenced = false
  for (const line of text.split('\n')) {
    if (/^(```|~~~)/.test(line.trimStart())) fenced = !fenced
    if (!fenced && line.trim() === '' && !/^(```|~~~)/.test(line.trimStart())) {
      if (current.length > 0) {
        blocks.push(current.join('\n'))
        current = []
      }
    } else {
      current.push(line)
    }
  }
  if (current.length > 0) blocks.push(current.join('\n'))
  return blocks
}

// Last-blocks-unstable: committed blocks render once (memoized by content);
// only the tail block re-renders as deltas arrive.
function StreamingMarkdown({ text }: { text: string }) {
  const blocks = splitBlocks(text)
  const tail = blocks.at(-1)
  return (
    <article className='wuhu-markdown'>
      {blocks.slice(0, -1).map((block, index) => (
        <Block key={index} source={block} />
      ))}
      {tail != null && <Markdown>{tail}</Markdown>}
    </article>
  )
}

export function TurnTimeline({ projection, status, ...actions }: Actions & {
  projection: TurnProjection
  status: string | null
}) {
  return (
    <div className='wuhu-turns'>
      {status !== null && <p className='wuhu-turn-status'>{status}</p>}
      {projection.rows.map((row) => {
        const rail = row.kind === 'summary' ||
          (row.kind === 'item' &&
            (!['text', 'send'].includes(row.item.content.kind) ||
              row.item.label === 'Preamble'))
        return (
          <div
            key={row.key}
            data-history-id={row.key}
            className={rail ? 'wuhu-transcript-work' : 'wuhu-transcript-output'}
          >
            {row.kind === 'input' && (
              <WakeLine
                wake={row.wake}
                clamped={false}
                group={actions.group}
                names={actions.names}
                open={() => actions.inspect({ kind: 'event', id: row.wake.id })}
              />
            )}
            {row.kind === 'divider' && (
              <button
                type='button'
                className='wuhu-turn-divider'
                onClick={() =>
                  actions.inspect({ kind: 'event', id: row.event })}
              >
                <span>
                  Context continued <Icon name='chevronRight' />
                </span>
              </button>
            )}
            {row.kind === 'gap' && (
              <p className='wuhu-turn-label'>Earlier work is not loaded</p>
            )}
            {rowAnchors(row).map((key) => (
              <span
                key={key}
                className='wuhu-summary-anchor'
                data-history-id={key}
                aria-hidden='true'
              />
            ))}
            {row.kind === 'summary' && (
              <button
                type='button'
                className='wuhu-turn-summary'
                onClick={() =>
                  actions.inspect({ kind: 'history', summary: row.key })}
              >
                <Icon name='hammer' />
                <span>{row.working ? 'Working' : 'Worked'}</span>
                {summaryText(row.tools, row.duration) !== '' && (
                  <span className='wuhu-muted'>
                    {summaryText(row.tools, row.duration)}
                  </span>
                )}
                <Icon name='chevronRight' />
              </button>
            )}
            {row.kind === 'item' && (
              <StepLine
                step={row.item}
                preamble={rail && row.item.content.kind === 'text'}
                names={actions.names}
                inspect={actions.inspect}
              />
            )}
          </div>
        )
      })}
      {projection.isWorking && status === null && (
        <div className='wuhu-transcript-work'>
          <Working />
        </div>
      )}
    </div>
  )
}

function WakeLine({
  wake,
  clamped,
  group,
  names,
  open,
}: {
  wake: Wake
  clamped: boolean
  group: string
  names: Names
  open: () => void
}) {
  const origin = useGroupOrigin(group)
  const label = wakeLabel(wake, names)
  const text = wakeText(wake)
  return (
    <div className='wuhu-turn-wake'>
      <button type='button' className='wuhu-turn-wake-head' onClick={open}>
        {label.tag !== null && (
          <span className='wuhu-turn-tag' data-tone={label.tone}>
            {label.tag}
          </span>
        )}
        {label.name !== null && <strong>{label.name}</strong>}
        {label.timestamp !== null && (
          <time dateTime={label.timestamp.toISOString()}>
            {wakeTime(label.timestamp, new Date())}
          </time>
        )}
      </button>
      {clamped
        ? <p className='wuhu-turn-clamped'>{preview(text)}</p>
        : text !== '' && (
          <article className='wuhu-markdown'>
            <Markdown>{text}</Markdown>
          </article>
        )}
      {wake.source.kind === 'input' && (
        <Attachments
          attachments={wake.source.input.attachments}
          origin={origin}
          crossOrigin={crossOriginFor(group)}
        />
      )}
    </div>
  )
}

function StepLine({
  step,
  names,
  inspect,
  preamble,
}: {
  preamble: boolean
  step: WorkItem
  names: Names
  inspect: (destination: Destination) => void
}) {
  const openEvent = () => inspect({ kind: 'event', id: step.event })
  const content = step.content
  switch (content.kind) {
    case 'text':
      if (preamble) {
        return (
          <Chip
            icon='reply'
            title='Preamble'
            detail={step.subject}
            open={openEvent}
          />
        )
      }
      return content.streaming
        ? (
          <div className='wuhu-turn-text' data-streaming>
            <StreamingMarkdown text={content.text} />
            <p className='wuhu-turn-label'>Writing…</p>
          </div>
        )
        : (
          <div className='wuhu-turn-text'>
            <article className='wuhu-markdown'>
              <Markdown>{content.text}</Markdown>
            </article>
            <span className='wuhu-turn-actions'>
              <button
                type='button'
                className='wuhu-quiet-button'
                onClick={openEvent}
              >
                details
              </button>
              <CopyButton text={content.text} />
            </span>
          </div>
        )
    case 'reasoning':
      return <Chip icon='sparkle' title='Reasoning' open={openEvent} />
    case 'tool':
      return (
        <ToolLine
          tool={content.tool}
          open={() => inspect({ kind: 'tool', callID: content.tool.callID })}
        />
      )
    case 'send': {
      const failed = toolState(content.tool) === 'failed'
      return (
        <button
          type='button'
          className='wuhu-turn-bubble'
          onClick={() => inspect({ kind: 'tool', callID: content.tool.callID })}
        >
          <span className='wuhu-turn-bubble-target'>
            {sendTarget(content.outgoing, names)}
            {failed && <span className='wuhu-turn-failed'>· Failed</span>}
          </span>
          {content.outgoing.text !== '' && (
            <span className='wuhu-turn-clamped'>
              {preview(content.outgoing.text)}
            </span>
          )}
        </button>
      )
    }
    case 'notice':
      return (
        <Chip
          icon='info'
          title={step.label}
          detail={step.subject}
          open={openEvent}
        />
      )
    case 'bookmark':
      return (
        <Chip
          icon='bookmark'
          title='Bookmark'
          detail={content.name}
          open={openEvent}
        />
      )
    case 'orphanResult':
      return (
        <Chip
          icon={content.result.failed ? 'warning' : 'reply'}
          title='Tool result'
          detail={content.result.kind}
          open={openEvent}
        />
      )
  }
}

function Chip({
  icon,
  title,
  detail,
  open,
}: {
  icon: IconName
  title: string
  detail?: string | null
  open?: () => void
}) {
  const body = (
    <>
      <Icon name={icon} />
      <span className='wuhu-turn-chip-title'>{title}</span>
      {detail != null && detail !== '' && (
        <>
          <span aria-hidden='true'>·</span>
          <span className='wuhu-turn-chip-detail'>{detail}</span>
        </>
      )}
      {open !== undefined && <Icon name='chevronRight' />}
    </>
  )
  return open === undefined ? <p className='wuhu-turn-chip'>{body}</p> : (
    <button
      type='button'
      className='wuhu-turn-chip'
      onClick={open}
    >
      {body}
    </button>
  )
}

export function ToolLine({
  tool,
  open,
}: {
  tool: ToolActivity
  open: () => void
}) {
  const state = toolState(tool)
  const subject = toolSubject(tool)
  return (
    <button type='button' className='wuhu-turn-tool' onClick={open}>
      <span className='wuhu-turn-tool-name'>{baseName(tool)}</span>
      {subject !== null && (
        <span className='wuhu-turn-tool-subject'>{subject}</span>
      )}
      <span className='wuhu-turn-tool-state' data-state={state}>
        {toolStateLabel[state]}
      </span>
    </button>
  )
}

function Working() {
  return (
    <p className='wuhu-turn-working' role='status'>
      <span aria-hidden='true' /> Working
    </p>
  )
}
