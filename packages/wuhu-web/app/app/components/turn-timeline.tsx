import { type CSSProperties, memo } from 'react'
import { Icon, type IconName } from '@wuhu/ui'
import { Attachments } from '~/components/attachments'
import { CopyButton } from '~/components/copy-button'
import { Markdown } from '~/components/markdown-view'
import {
  firstLine,
  type Names,
  noticeLabel,
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
  latestTurn,
  type ToolActivity,
  toolState,
  toolSubject,
  type Turn,
  type TurnLine,
  turnLines,
  type TurnProjection,
  type TurnStep,
  type Wake,
  wakeText,
} from '~/lib/turns'
import { eventKey } from '~/lib/work-events'
import { useGroupOrigin } from '~/lib/use-directory'
import { crossOriginFor } from '~/lib/groups'

interface Actions {
  // The session's group, whose content origin holds what its wakes attach.
  group: string
  names: Names
  inspect: (destination: Destination) => void
  toggle: (turn: string, anchor: Element) => void
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

export function TurnTimeline({
  projection,
  expanded,
  status,
  ...actions
}: Actions & {
  projection: TurnProjection
  expanded: ReadonlySet<string>
  status: string | null
}) {
  const latest = latestTurn(projection)
  return (
    <div className='wuhu-turns'>
      {status !== null && <p className='wuhu-turn-status'>{status}</p>}
      {projection.items.map((item, index) => {
        if (item.kind === 'divider') {
          return (
            <Divider
              key={eventKey(item.id)}
              open={() => actions.inspect({ kind: 'event', id: item.id })}
            />
          )
        }
        const key = eventKey(item.turn.id)
        const isLatest = item.turn === latest
        return (
          <TurnSection
            key={key}
            turn={item.turn}
            latest={isLatest}
            unfolded={isLatest || expanded.has(key)}
            working={isLatest && projection.isWorking}
            separated={projection.items[index - 1]?.kind === 'turn'}
            {...actions}
          />
        )
      })}
      {projection.isWorking && latest === null && status === null &&
        <Working />}
    </div>
  )
}

function Divider({ open }: { open: () => void }) {
  return (
    <button type='button' className='wuhu-turn-divider' onClick={open}>
      <span>
        <strong>Context continued</strong> · summary and note{' '}
        <Icon name='chevronRight' />
      </span>
    </button>
  )
}

type Dot = 'quiet' | 'send' | 'text'

// Where a line sits on the rail, and the height of its dot's centre; null
// keeps it off.
function railDot(line: TurnLine): { dot: Dot; center: number } | null {
  switch (line.kind) {
    case 'wake':
    case 'continued':
    case 'summary':
    case 'fallback':
      return null
    case 'fold':
      return { dot: 'quiet', center: 14 }
    case 'step':
      switch (line.step.content.kind) {
        case 'text':
          return { dot: 'text', center: 15 }
        case 'send':
          return { dot: 'send', center: 16 }
        case 'notice':
          return { dot: 'quiet', center: 18 }
        default:
          return { dot: 'quiet', center: 14 }
      }
  }
}

function TurnSection({
  turn,
  latest,
  unfolded,
  working,
  separated,
  ...actions
}: Actions & {
  turn: Turn
  latest: boolean
  unfolded: boolean
  working: boolean
  separated: boolean
}) {
  const lines = turnLines(turn, !latest, unfolded)
  const headingCount = unfolded
    ? lines.findIndex((line) => railDot(line) !== null)
    : -1
  const heading = headingCount === -1 ? lines : lines.slice(0, headingCount)
  const railed = headingCount === -1 ? [] : lines.slice(headingCount)
  const key = eventKey(turn.id)
  return (
    <section
      className='wuhu-turn'
      data-separated={separated || undefined}
      aria-label={latest ? 'Latest turn' : undefined}
    >
      {heading.map((line) => (
        <Line
          key={line.key}
          line={line}
          group={actions.group}
          names={actions.names}
          inspect={actions.inspect}
          toggle={(anchor) => actions.toggle(key, anchor)}
        />
      ))}
      {(railed.length > 0 || working) && (
        <ol
          className='wuhu-turn-rail'
          data-line={railed.length + (working ? 1 : 0) > 1 || undefined}
        >
          {railed.map((line) => {
            const dot = railDot(line)!
            return (
              <li
                key={line.key}
                data-dot={dot.dot}
                style={{ '--dot': `${dot.center}px` } as CSSProperties}
              >
                <Line
                  line={line}
                  group={actions.group}
                  names={actions.names}
                  inspect={actions.inspect}
                  toggle={(anchor) => actions.toggle(key, anchor)}
                />
              </li>
            )
          })}
          {working && (
            <li data-dot='quiet' style={{ '--dot': '14px' } as CSSProperties}>
              <Working />
            </li>
          )}
        </ol>
      )}
    </section>
  )
}

function Line({
  line,
  toggle,
  group,
  names,
  inspect,
}: Omit<Actions, 'toggle'> & {
  line: TurnLine
  toggle: (anchor: Element) => void
}) {
  switch (line.kind) {
    case 'wake':
      return (
        <WakeLine
          wake={line.wake}
          clamped={line.clamped}
          group={group}
          names={names}
          open={() => inspect({ kind: 'event', id: line.wake.id })}
        />
      )
    case 'continued':
      return (
        <p className='wuhu-turn-label'>
          <Icon name='rotate' /> Continued after compaction
        </p>
      )
    case 'summary': {
      const text = summaryText(line.tools, line.duration)
      return (
        <button
          type='button'
          className='wuhu-turn-summary'
          aria-expanded={line.expanded}
          onClick={(event) => toggle(event.currentTarget)}
        >
          <Icon name='hammer' /> {text}{' '}
          <Icon name={line.expanded ? 'chevronDown' : 'chevronRight'} />
        </button>
      )
    }
    case 'step':
      return <StepLine step={line.step} names={names} inspect={inspect} />
    case 'fold':
      return (
        <button
          type='button'
          className='wuhu-turn-summary'
          onClick={() =>
            inspect({
              kind: 'history',
              calls: line.tools.map((tool) => tool.callID),
            })}
        >
          <Icon name='hammer' /> {line.tools.length} tools{' '}
          <Icon name='chevronRight' />
        </button>
      )
    case 'fallback':
      return <p className='wuhu-turn-fallback'>{preview(line.text)}</p>
  }
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
}: {
  step: TurnStep
  names: Names
  inspect: (destination: Destination) => void
}) {
  const openEvent = () => inspect({ kind: 'event', id: step.event })
  const content = step.content
  switch (content.kind) {
    case 'text':
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
          title={noticeLabel(content.notice.kind)}
          detail={firstLine(content.notice.text)}
          boxed
          open={openEvent}
        />
      )
    case 'bookmark':
      return <Chip icon='bookmark' title='Bookmark' detail={content.name} />
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
  boxed = false,
  open,
}: {
  icon: IconName
  title: string
  detail?: string | null
  boxed?: boolean
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
      {open !== undefined && !boxed && <Icon name='chevronRight' />}
    </>
  )
  return open === undefined ? <p className='wuhu-turn-chip'>{body}</p> : (
    <button
      type='button'
      className='wuhu-turn-chip'
      data-boxed={boxed || undefined}
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
