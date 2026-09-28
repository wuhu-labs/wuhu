import { useMemo, useState } from 'react'
import { useChrome } from '@wuhu/ui'
import { useFollowLatest } from '~/components/conversation-timeline'
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
} from '~/lib/transcript-fold'
import {
  closedInspection,
  followInspection,
  historyReturned,
  inspected,
  type Inspection,
  turnToggled,
} from '~/lib/turn-inspection'
import { type Names, turnStatus } from '~/lib/turn-labels'
import { projectTurns } from '~/lib/turns'
import { useDirectory, useSessionTitles } from '~/lib/use-directory'
import { useObserve } from '~/lib/use-observe'
import { workEvents } from '~/lib/work-events'
import { directSubscription } from '~/sdk/subscriptions'

// A task's page and an agent's transcript: the turn view of the session's
// direct stream, with no composer.
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
  const { hold } = useFollowLatest(canvas)
  const direct = useObserve<DirectState, SessionStreamEvent>(
    directSubscription(id, record.group),
    foldDirect,
    initialDirectState,
  )
  const state = direct.data
  const working = record.work === 'has_work'
  const projection = useMemo(
    () => projectTurns(workEvents(state), working),
    [state, working],
  )
  const [expanded, setExpanded] = useState<ReadonlySet<string>>(new Set())
  const [inspection, setInspection] = useState<Inspection>(closedInspection)
  const directory = useDirectory()
  const sessions = useSessionTitles()
  const names: Names = {
    session: (session) => sessions.titles.get(session),
    principal: (principal) => principalName(directory, sessions, principal),
  }

  return (
    <div className='wuhu-content wuhu-page'>
      <SessionHeader id={id} record={record} liveness={direct.liveness} />
      <TurnTimeline
        projection={projection}
        expanded={expanded}
        status={turnStatus(
          isEmptyDirect(state),
          direct.liveness === 'live',
          working,
        )}
        group={record.group}
        names={names}
        inspect={(destination) =>
          setInspection((current) => inspected(current, destination))}
        toggle={(turn, anchor) => {
          hold(anchor)
          setExpanded((open) => turnToggled(open, turn))
        }}
      />
      <TurnInspector
        inspection={followInspection(inspection, state)}
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
