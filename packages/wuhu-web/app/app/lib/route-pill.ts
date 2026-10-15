import {
  type RouteFailure,
  type RouteNote,
  routeNote,
  type SessionRoute,
  stillRecovered,
} from './model-route.ts'

export interface RoutePill {
  route: SessionRoute
  recovered: boolean
  failure: RouteFailure | null
  now: Date
}

export type RoutePillEvent =
  | { kind: 'route'; route: SessionRoute }
  | { kind: 'failure'; failure: RouteFailure | null }
  | { kind: 'tick'; now: Date }

export function routePill(route: SessionRoute, now: Date): RoutePill {
  return { route, recovered: false, failure: null, now }
}

// A failure belongs to the waiting episode it was read for: it survives a
// refetch of the same pin and clears when the route moves or stops waiting.
export function stepRoutePill(
  pill: RoutePill,
  event: RoutePillEvent,
): RoutePill {
  switch (event.kind) {
    case 'route': {
      const route = event.route
      const samePin = pill.route.epoch === route.epoch &&
        pill.route.member === route.member
      return {
        ...pill,
        route,
        recovered: stillRecovered(pill.route, route, pill.recovered),
        failure: route.phase === 'waiting' && samePin ? pill.failure : null,
      }
    }
    case 'failure':
      return pill.route.phase === 'waiting'
        ? { ...pill, failure: event.failure }
        : pill
    case 'tick':
      return { ...pill, now: event.now }
  }
}

// What the pill reads the failure for: the waiting episode, each rewrite of
// its failure, and each reconnect. Null when nothing is waiting.
export function routeFailureKey(
  route: SessionRoute,
  liveness: string,
): string | null {
  if (route.phase !== 'waiting') return null
  return [route.epoch, route.member, route.failureRevision ?? '', liveness]
    .join('\u0000')
}

export function routePillNote(
  pill: RoutePill,
  failureLine = false,
): RouteNote {
  return routeNote(
    pill.route,
    pill.failure,
    pill.recovered,
    pill.now,
    undefined,
    failureLine,
  )
}
