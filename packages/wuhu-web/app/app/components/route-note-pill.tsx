import { useEffect, useReducer } from 'react'
import { Pill } from '@wuhu/ui'
import { routeFailureOf, type SessionRoute } from '~/lib/model-route'
import {
  routeFailureKey,
  routePill,
  routePillNote,
  stepRoutePill,
} from '~/lib/route-pill'
import type { Liveness } from '~/sdk/observe'
import { fetchModelRoute } from '~/sdk/session'

// Where a group session runs and why. A waiting route reads its failure from
// the server for the switch deadline, and turns blocked when that passes.
// Beside the header's failure line, a blocked pill leaves the cause to it.
export function RouteNotePill(
  { id, group, route, liveness, failureLine }: {
    id: string
    group: string
    route: SessionRoute
    liveness: Liveness
    failureLine: boolean
  },
) {
  const [pill, send] = useReducer(
    stepRoutePill,
    route,
    (initial) => routePill(initial, new Date()),
  )

  useEffect(() => send({ kind: 'route', route }), [route])

  const key = routeFailureKey(route, liveness)
  useEffect(() => {
    if (key == null) return
    let cancelled = false
    fetchModelRoute({ id, group }).then(
      (output) => {
        if (!cancelled) {
          send({ kind: 'failure', failure: routeFailureOf(output) })
        }
      },
      () => undefined,
    )
    return () => {
      cancelled = true
    }
  }, [id, group, key])

  const deadline = pill.route.phase === 'waiting'
    ? pill.failure?.deadline?.getTime() ?? null
    : null
  useEffect(() => {
    send({ kind: 'tick', now: new Date() })
    if (deadline == null) return
    const delay = deadline - Date.now()
    if (delay < 0) return
    const timer = setTimeout(
      () => send({ kind: 'tick', now: new Date() }),
      delay,
    )
    return () => clearTimeout(timer)
  }, [deadline])

  const note = routePillNote(pill, failureLine)
  return <Pill tone={note.tone} dot>{note.text}</Pill>
}
