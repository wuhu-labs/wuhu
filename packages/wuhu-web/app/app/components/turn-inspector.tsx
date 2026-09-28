import { useEffect, useRef } from 'react'
import { Icon } from '@wuhu/ui'
import { ToolLine } from '~/components/turn-timeline'
import type { DirectState } from '~/lib/transcript-fold'
import {
  type Destination,
  type EventDetails,
  eventDetails,
  type Inspection,
} from '~/lib/turn-inspection'
import { toolStateLabel } from '~/lib/turn-labels'
import { activity, baseName, toolState, type TurnProjection } from '~/lib/turns'

function payloadText(value: unknown): string {
  return typeof value === 'string' ? value : JSON.stringify(value, null, 2)
}

function Payload({ title, value }: { title: string; value: unknown }) {
  return (
    <section className='wuhu-inspector-section'>
      <h3 className='wuhu-eyebrow'>{title}</h3>
      <pre className='wuhu-inspector-payload'>{payloadText(value)}</pre>
    </section>
  )
}

export function TurnInspector({
  inspection,
  projection,
  state,
  inspect,
  returnToHistory,
  close,
}: {
  inspection: Inspection
  projection: TurnProjection
  state: DirectState
  inspect: (destination: Destination) => void
  returnToHistory: () => void
  close: () => void
}) {
  const inspecting = inspection.destination
  const dialog = useRef<HTMLDialogElement>(null)

  useEffect(() => {
    const element = dialog.current!
    if (inspecting !== null && !element.open) element.showModal()
    if (inspecting === null && element.open) element.close()
  }, [inspecting])

  const tool = inspecting?.kind === 'tool'
    ? activity(projection, inspecting.callID)
    : null
  const details = inspecting?.kind === 'event'
    ? eventDetails(state, inspecting.id)
    : null
  const title = inspecting?.kind === 'tool'
    ? tool === null ? 'Tool' : baseName(tool)
    : inspecting?.kind === 'history'
    ? 'Tool history'
    : details?.title ?? 'Event details'

  return (
    <dialog
      ref={dialog}
      className='wuhu-composer-dialog wuhu-inspector'
      aria-label={title}
      onClose={close}
    >
      {inspecting !== null && (
        <div className='wuhu-composer-dialog-body'>
          <header className='wuhu-inspector-head'>
            {inspecting.kind === 'tool' && inspection.history.length > 0 && (
              <button
                type='button'
                className='wuhu-quiet-button'
                onClick={returnToHistory}
              >
                ‹ Tool history
              </button>
            )}
            <h2 className='wuhu-dialog-title'>{title}</h2>
            <button
              type='button'
              className='wui-icon-button'
              aria-label='Close'
              onClick={close}
            >
              <Icon name='xmark' />
            </button>
          </header>
          {inspecting.kind === 'tool' && (tool === null
            ? (
              <p className='wuhu-muted'>
                This tool is not available in the current generation.
              </p>
            )
            : (
              <>
                <p className='wuhu-inspector-facts'>
                  <span>{tool.callID}</span>
                  <span>{toolStateLabel[toolState(tool)]}</span>
                </p>
                <Payload title='Arguments' value={tool.arguments} />
                {tool.result === null
                  ? <p className='wuhu-muted'>Waiting for output…</p>
                  : <Payload title='Output' value={tool.result.output} />}
              </>
            ))}
          {inspecting.kind === 'history' && (
            <div className='wuhu-inspector-history'>
              {inspecting.calls.map((callID) => {
                const call = activity(projection, callID)
                return call === null ? null : (
                  <ToolLine
                    key={callID}
                    tool={call}
                    open={() => inspect({ kind: 'tool', callID })}
                  />
                )
              })}
            </div>
          )}
          {inspecting.kind === 'event' && (details === null
            ? (
              <p className='wuhu-muted'>
                This event is not available in the current generation.
              </p>
            )
            : <Event details={details} />)}
        </div>
      )}
    </dialog>
  )
}

function Event({ details }: { details: EventDetails }) {
  return (
    <>
      <dl className='wuhu-inspector-grid'>
        {details.timestamp !== null && (
          <>
            <dt>Time</dt>
            <dd>
              {details.timestamp.toLocaleString(undefined, {
                month: 'short',
                day: 'numeric',
                hour: 'numeric',
                minute: '2-digit',
                second: '2-digit',
              })}
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
      {details.text !== null && details.text !== '' && (
        <section className='wuhu-inspector-section'>
          <h3 className='wuhu-eyebrow'>Text</h3>
          <p className='wuhu-inspector-text'>{details.text}</p>
        </section>
      )}
      {details.payload !== undefined && (
        <Payload title='Payload' value={details.payload} />
      )}
    </>
  )
}
