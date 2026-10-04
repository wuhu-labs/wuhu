import { useEffect, useMemo, useState } from 'react'
import { useChrome } from '@wuhu/ui'
import { useFollowLatest } from '~/components/conversation-timeline'
import { HistoryEdge, useOlderIntent } from '~/components/history-edge'
import { SessionHeader } from '~/components/session-header'
import { TurnInspector } from '~/components/turn-inspector'
import { TurnTimeline } from '~/components/turn-timeline'
import type { SessionStreamEvent } from '~/lib/contract.gen'
import { principalName } from '~/lib/directory'
import type { SessionRecord } from '~/lib/session-model'
import {
  type DirectState,
  foldDirect,
  initialDirectState,
  isEmptyDirect,
  parseTranscriptItem,
} from '~/lib/transcript-fold'
import {
  closedInspection,
  followInspection,
  historyReturned,
  inspected,
  type Inspection,
  validInspection,
} from '~/lib/turn-inspection'
import { type Names, turnStatus } from '~/lib/turn-labels'
import { projectTurns } from '~/lib/turns'
import { useDirectory, useSessionTitles } from '~/lib/use-directory'
import { useObserve } from '~/lib/use-observe'
import { runningCall, workEvents } from '~/lib/work-events'
import { directSubscription } from '~/sdk/subscriptions'

export function SessionTranscript({
  id,
  record,
}: {
  id: string
  record: SessionRecord
}) {
  if (record.executorLabel.startsWith('contractor:')) {
    return (
      <div className='wuhu-content wuhu-page'>
        <SessionHeader id={id} record={record} liveness='live' />
        <p className='wuhu-muted'>
          This session ran on the removed contractor executor; its transcript is
          no longer shown. Start it over on a model to use it again.
        </p>
      </div>
    )
  }
  return <Turns key={id} id={id} record={record} />
}

function Turns({ id, record }: { id: string; record: SessionRecord }) {
  const { canvas } = useChrome()
  const direct = useObserve<DirectState, SessionStreamEvent>(
    directSubscription(id, record.group),
    foldDirect,
    initialDirectState,
  )
  useOlderIntent(canvas, direct.history)
  const state = direct.data
  const identity = `${state.generation}:${direct.history?.historyEpoch ?? ''}:${
    direct.history?.resetVersion ?? 0
  }`
  const { following, pin } = useFollowLatest(canvas, identity)
  const working = record.work === 'has_work'
  const projection = useMemo(
    () => {
      const origins = new Map<number, import('~/sdk/session').TranscriptItem>()
      for (const raw of direct.origins ?? []) {
        const event = raw as SessionStreamEvent
        if (event.kind !== 'item') continue
        const item = parseTranscriptItem(event.item)
        if (item) origins.set(event.position, item)
      }
      return projectTurns(workEvents(state), working, {
        origins: workEvents({
          ...initialDirectState,
          generation: state.generation,
          items: origins,
        }),
        runningCall: runningCall(state, working, direct.liveness === 'live'),
      })
    },
    [state, working, direct.origins, direct.history, direct.liveness],
  )
  const [inspection, setInspection] = useState<Inspection>(closedInspection)
  useEffect(() => {
    setInspection(closedInspection)
  }, [state.generation, direct.history?.historyEpoch])
  const directory = useDirectory()
  const sessions = useSessionTitles()
  const names: Names = {
    session: (session) => sessions.titles.get(session),
    principal: (principal) => principalName(directory, sessions, principal),
  }

  return (
    <div className='wuhu-content wuhu-page'>
      <SessionHeader id={id} record={record} liveness={direct.liveness} />
      <HistoryEdge edge={direct.history} />
      <TurnTimeline
        projection={projection}
        status={turnStatus(
          isEmptyDirect(state),
          direct.liveness === 'live',
          working,
        )}
        group={record.group}
        names={names}
        inspect={(destination) =>
          setInspection((current) => inspected(current, destination))}
      />
      {!following && !isEmptyDirect(state) && (
        <button
          type='button'
          aria-label='Jump to latest'
          className='wuhu-jump'
          onClick={pin}
        >
          ↓ latest
        </button>
      )}
      <TurnInspector
        inspection={validInspection(
          followInspection(inspection, state),
          projection,
          state,
        )}
        projection={projection}
        state={state}
        inspect={(destination) =>
          setInspection((current) => inspected(current, destination))}
        returnToHistory={() => setInspection(historyReturned)}
        close={() => setInspection(closedInspection)}
      />
    </div>
  )
}
