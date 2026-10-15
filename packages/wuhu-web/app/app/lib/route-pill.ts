import {
  type RouteFailure,
  type RouteNote,
  routeNote,
  type SessionRoute,
} from './model-route.ts'

// The waiting pin a failure was read for, or that the pill last saw waiting.
export interface RoutePin {
  group: string
  epoch: string
  member: string
}

// What the pill holds beyond its route: the pin it last saw waiting, the
// failure read for a waiting pin, and the clock. The route itself is read
// fresh at every render.
export interface RoutePillHeld {
  waited: RoutePin | null
  failure: { pin: RoutePin; failure: RouteFailure | null } | null
  now: Date
}

export type RoutePillEvent =
  | { kind: 'waiting'; pin: RoutePin }
  | { kind: 'settled' }
  | { kind: 'failure'; pin: RoutePin; failure: RouteFailure | null }
  | { kind: 'tick'; now: Date }

export interface RoutePill {
  route: SessionRoute
  recovered: boolean
  failure: RouteFailure | null
  now: Date
}

export function routePillHeld(now: Date): RoutePillHeld {
  return { waited: null, failure: null, now }
}

export function routePin(route: SessionRoute): RoutePin {
  return { group: route.group, epoch: route.epoch, member: route.member }
}

function samePin(a: RoutePin, b: RoutePin): boolean {
  return a.group === b.group && a.epoch === b.epoch && a.member === b.member
}

// A failure belongs to the waiting episode it was read for: it survives a
// refetch of the same pin and clears when the route moves or stops waiting.
export function stepRoutePill(
  held: RoutePillHeld,
  event: RoutePillEvent,
): RoutePillHeld {
  switch (event.kind) {
    case 'waiting': {
      const keeps = held.failure != null && samePin(held.failure.pin, event.pin)
      return {
        ...held,
        waited: event.pin,
        failure: keeps ? held.failure : null,
      }
    }
    case 'settled':
      return held.failure == null ? held : { ...held, failure: null }
    case 'failure':
      return held.waited != null && samePin(held.waited, event.pin)
        ? { ...held, failure: { pin: event.pin, failure: event.failure } }
        : held
    case 'tick':
      return { ...held, now: event.now }
  }
}

// The pill for the route as it is now. A route that leaves waiting on the pin
// the pill saw waiting has recovered; it stays recovered until the route
// moves or waits again.
export function routePill(route: SessionRoute, held: RoutePillHeld): RoutePill {
  const waiting = route.phase === 'waiting'
  const pin = routePin(route)
  const failure = waiting && held.failure != null &&
      samePin(held.failure.pin, pin)
    ? held.failure.failure
    : null
  const recovered = !waiting && held.waited != null &&
    held.waited.group === route.group && held.waited.epoch === route.epoch
  return { route, recovered, failure, now: held.now }
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
