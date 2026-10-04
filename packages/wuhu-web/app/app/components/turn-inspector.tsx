import { useEffect, useLayoutEffect, useRef } from 'react'
import { Icon } from '@wuhu/ui'
import { CopyButton } from '~/components/copy-button'
import type { DirectState } from '~/lib/transcript-fold'
import {
  type Destination,
  type EventDetails,
  eventDetails,
  historyRow,
  type Inspection,
} from '~/lib/turn-inspection'
import { toolStateLabel } from '~/lib/turn-labels'
import {
  activity,
  baseName,
  rowAtAnchor,
  toolState,
  type TurnProjection,
  type WorkItem,
} from '~/lib/turns'
import { eventKey } from '~/lib/work-events'
import {
  historyPosition,
  initialHistoryPosition,
  restoredHistoryTop,
} from '~/lib/history-position'

function historyBounds(element: HTMLElement) {
  return [...element.querySelectorAll<HTMLElement>('[data-event-id]')].map(
    (row) => {
      const rect = row.getBoundingClientRect()
      return { id: row.dataset.eventId!, top: rect.top, bottom: rect.bottom }
    },
  )
}

function payloadText(value: unknown): string {
  return typeof value === 'string' ? value : JSON.stringify(value, null, 2)
}

function Payload({ title, value }: { title: string; value: unknown }) {
  const text = payloadText(value)
  return (
    <section className='wuhu-inspector-section'>
      <div className='wuhu-inspector-section-head'>
        <h3 className='wuhu-eyebrow'>{title}</h3>
        <CopyButton text={text} />
      </div>
      <pre className='wuhu-inspector-payload'>{text}</pre>
    </section>
  )
}

export function HistoryItem(
  { item, open }: { item: WorkItem; open: () => void },
) {
  const content = item.content
  const tool = content.kind === 'tool' || content.kind === 'send'
    ? content.tool
    : null
  const secondary = item.subject ??
    (item.inference
      ? `Inference ${item.inference} · block ${
        item.event.kind === 'kernel' ? item.event.part : 0
      }`
      : null)
  return (
    <button
      type='button'
      className='wuhu-history-row'
      aria-label={[
        item.label,
        item.subject,
        item.inference
          ? `Inference ${item.inference}, block ${
            item.event.kind === 'kernel' ? item.event.part : 0
          }`
          : null,
        tool ? toolStateLabel[toolState(tool)] : null,
      ].filter(Boolean).join('. ')}
      data-event-id={item.key}
      onClick={open}
    >
      <Icon
        name={tool
          ? 'hammer'
          : content.kind === 'reasoning'
          ? 'sparkle'
          : content.kind === 'notice'
          ? 'info'
          : 'reply'}
      />
      <strong>{item.label}</strong>
      {secondary !== null && (
        <span className='wuhu-history-subject'>{secondary}</span>
      )}
      {tool !== null && (
        <span className='wuhu-turn-tool-state' data-state={toolState(tool)}>
          {toolStateLabel[toolState(tool)]}
        </span>
      )}
      <Icon name='chevronRight' />
    </button>
  )
}

export function TurnInspector(
  { inspection, projection, state, inspect, returnToHistory, close }: {
    inspection: Inspection
    projection: TurnProjection
    state: DirectState
    inspect: (destination: Destination) => void
    returnToHistory: () => void
    close: () => void
  },
) {
  const inspecting = inspection.destination
  const dialog = useRef<HTMLDialogElement>(null)
  const scroller = useRef<HTMLDivElement>(null)
  const trigger = useRef<HTMLElement | null>(null)
  const triggerID = useRef<string | null>(null)
  const savedHistory = useRef(initialHistoryPosition)
  const wasHistory = useRef(false)

  useEffect(() => {
    const element = dialog.current!
    if (inspecting !== null && !element.open) {
      trigger.current = document.activeElement as HTMLElement
      triggerID.current =
        trigger.current.closest<HTMLElement>('[data-history-id]')?.dataset
          .historyId ?? null
      savedHistory.current = initialHistoryPosition
      element.showModal()
      if (inspecting.kind === 'history') rememberHistory()
    }
    if (inspecting === null && element.open) {
      element.close()
      if (trigger.current?.isConnected) trigger.current.focus()
      else if (triggerID.current !== null) {
        const anchor = rowAtAnchor(projection, triggerID.current)?.key
        if (anchor) {
          document.querySelector<HTMLElement>(
            `[data-history-id="${CSS.escape(anchor)}"] button`,
          )?.focus()
        }
      }
    }
  }, [inspecting, projection])

  const rememberHistory = (focus = savedHistory.current.focus) => {
    const element = scroller.current
    if (element) {
      savedHistory.current = historyPosition(
        element.scrollTop,
        element.getBoundingClientRect().top,
        historyBounds(element),
        focus,
      )
    }
  }

  useLayoutEffect(() => {
    const history = inspecting?.kind === 'history'
    const element = scroller.current
    if (element && history) {
      if (!dialog.current?.open) savedHistory.current = initialHistoryPosition
      element.scrollTop = restoredHistoryTop(
        savedHistory.current,
        element.scrollTop,
        element.getBoundingClientRect().top,
        historyBounds(element),
      )
      if (!wasHistory.current && savedHistory.current.focus) {
        element.querySelector<HTMLElement>(
          `[data-event-id="${CSS.escape(savedHistory.current.focus)}"]`,
        )?.focus({ preventScroll: true })
      }
      rememberHistory()
    } else if (element && wasHistory.current) {
      element.scrollTop = 0
      dialog.current?.querySelector<HTMLElement>('.wuhu-history-back, h2')
        ?.focus({ preventScroll: true })
    }
    wasHistory.current = history
  })

  const tool = inspecting?.kind === 'tool'
    ? activity(projection, inspecting.callID)
    : null
  const item = inspecting?.kind === 'tool'
    ? projection.items.find((item) =>
      (item.content.kind === 'tool' || item.content.kind === 'send') &&
      item.content.tool.callID === inspecting.callID
    )
    : inspecting?.kind === 'event'
    ? projection.items.find((item) => item.key === eventKey(inspecting.id))
    : null
  const details = inspecting?.kind === 'event'
    ? eventDetails(state, inspecting.id)
    : item
    ? eventDetails(state, item.event)
    : null
  const history = inspecting?.kind === 'history'
    ? historyRow(projection, inspecting.summary)
    : null
  const title = inspecting?.kind === 'history'
    ? 'Work history'
    : tool
    ? baseName(tool)
    : item?.label ?? details?.title ?? 'Event details'

  return (
    <dialog
      ref={dialog}
      className='wuhu-composer-dialog wuhu-inspector'
      aria-label={title}
      onKeyDownCapture={(event) => event.stopPropagation()}
      onCancel={(event) => {
        event.preventDefault()
        close()
      }}
    >
      {inspecting !== null && (
        <>
          <header className='wuhu-inspector-head'>
            <h2 className='wuhu-dialog-title' tabIndex={-1}>{title}</h2>
            <button
              type='button'
              className='wui-icon-button'
              aria-label='Close'
              onClick={close}
            >
              <Icon name='xmark' />
            </button>
          </header>
          <div
            ref={scroller}
            className='wuhu-inspector-body'
            onScroll={() => {
              if (inspecting.kind === 'history') rememberHistory()
            }}
          >
            {inspecting.kind !== 'history' && inspection.history !== null && (
              <button
                type='button'
                className='wuhu-history-back'
                onClick={returnToHistory}
              >
                <span aria-hidden='true'>‹</span> Back to work history
              </button>
            )}
            {item?.inference && (
              <p className='wuhu-inspector-facts'>
                Inference {item.inference} · block{' '}
                {item.event.kind === 'kernel' ? item.event.part : 0}
              </p>
            )}
            {inspecting.kind === 'history' && (
              <div className='wuhu-inspector-history'>
                {history?.items.map((item) => (
                  <HistoryItem
                    key={item.key}
                    item={item}
                    open={() => {
                      rememberHistory(item.key)
                      const content = item.content
                      inspect(
                        content.kind === 'tool' || content.kind === 'send'
                          ? { kind: 'tool', callID: content.tool.callID }
                          : { kind: 'event', id: item.event },
                      )
                    }}
                  />
                ))}
              </div>
            )}
            {tool && (
              <>
                <p className='wuhu-inspector-facts'>
                  <span>{tool.name} · {tool.callID}</span>
                  <span>{toolStateLabel[toolState(tool)]}</span>
                </p>
                <Payload title='Arguments' value={tool.arguments} />
                {tool.result === null
                  ? (
                    <p className='wuhu-muted'>
                      {toolState(tool) === 'unknown'
                        ? 'Execution state unknown; no result available.'
                        : toolState(tool) === 'queued'
                        ? 'Queued; no result yet.'
                        : 'Running; waiting for output…'}
                    </p>
                  )
                  : (
                    <Payload
                      title={tool.result.failed ? 'Error' : 'Result'}
                      value={tool.result.output}
                    />
                  )}
              </>
            )}
            {item && item.sources.length > 0 && (
              <Payload title='Instruction sources' value={item.sources} />
            )}
            {inspecting.kind !== 'history' && details && (
              <Event details={details} tool={tool !== null} />
            )}
          </div>
        </>
      )}
    </dialog>
  )
}

function Event({ details, tool }: { details: EventDetails; tool: boolean }) {
  return (
    <>
      <dl className='wuhu-inspector-grid'>
        {details.timestamp !== null && (
          <>
            <dt>Time</dt>
            <dd>
              <time dateTime={details.timestamp.toISOString()}>
                {details.timestamp.toLocaleString()}
              </time>
            </dd>
          </>
        )}
        {details.facts.map((fact) => (
          <div key={fact.label} className='contents'>
            <dt>{fact.label}</dt>
            <dd>{fact.value}</dd>
          </div>
        ))}
      </dl>
      {details.text !== null && (
        <Payload
          title='Text'
          value={details.text || 'No source body available.'}
        />
      )}
      {!tool && details.payload !== undefined && (
        <Payload title='Payload' value={details.payload} />
      )}
    </>
  )
}
