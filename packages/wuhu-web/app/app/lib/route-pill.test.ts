import { assertEquals, assertNotEquals } from 'jsr:@std/assert@1'
import type { RouteFailure, SessionRoute } from './model-route.ts'
import {
  routeFailureKey,
  routePill,
  routePillHeld,
  routePillNote,
  routePin,
  stepRoutePill,
} from './route-pill.ts'

const pinned: SessionRoute = {
  group: 'fleet',
  member: 'primary',
  phase: 'pinned',
  epoch: '3',
  reason: 'create',
  previousMember: null,
  failureRevision: null,
}
const waiting: SessionRoute = {
  ...pinned,
  phase: 'waiting',
  failureRevision: '{"reason":"quota"}',
}
const start = new Date('2026-10-14T21:00:00Z')
const deadline = new Date('2026-10-14T21:30:00Z')
const quota: RouteFailure = {
  reason: 'quota',
  source: 'upstream',
  code: 'refusal',
  deadline,
  retryAt: new Date('2026-10-14T22:00:00Z'),
}

// The fetch effect records the waiting pin, then the failure it read for it.
function waitedOn(route: SessionRoute, failure: RouteFailure | null) {
  const pin = routePin(route)
  const held = stepRoutePill(routePillHeld(start), { kind: 'waiting', pin })
  return stepRoutePill(held, { kind: 'failure', pin, failure })
}

Deno.test('a waiting pill turns blocked at its deadline', () => {
  let held = waitedOn(waiting, quota)
  assertEquals(routePillNote(routePill(waiting, held)).stage, 'waiting')
  held = stepRoutePill(held, { kind: 'tick', now: deadline })
  assertEquals(routePillNote(routePill(waiting, held)).stage, 'blocked')
  assertEquals(routePillNote(routePill(waiting, held)).tone, 'rose')
})

Deno.test('a pill that stops waiting on the same pin reads recovered until the route moves', () => {
  let held = waitedOn(waiting, quota)
  assertEquals(routePillNote(routePill(pinned, held)), {
    stage: 'recovered',
    text: 'fleet → primary · recovered',
    tone: 'live',
  })
  held = stepRoutePill(held, { kind: 'settled' })
  assertEquals(routePill(pinned, held).failure, null)
  assertEquals(routePillNote(routePill(pinned, held)).stage, 'recovered')
  const moved = {
    ...pinned,
    epoch: '4',
    member: 'backup',
    reason: 'compaction',
  }
  assertEquals(routePillNote(routePill(moved, held)).stage, 'pinned')
})

Deno.test('a route that leaves waiting on another pin has not recovered', () => {
  const held = waitedOn(waiting, quota)
  const elsewhere = { ...pinned, epoch: '4', member: 'backup' }
  assertEquals(routePill(elsewhere, held).recovered, false)
  assertEquals(routePill(pinned, routePillHeld(start)).recovered, false)
})

Deno.test('a new cause on the same waiting pin replaces the failure', () => {
  let held = waitedOn(waiting, quota)
  const rewritten = {
    ...waiting,
    failureRevision: '{"reason":"authentication"}',
  }
  held = stepRoutePill(held, { kind: 'waiting', pin: routePin(rewritten) })
  assertEquals(routePill(rewritten, held).failure, quota)
  held = stepRoutePill(held, {
    kind: 'failure',
    pin: routePin(rewritten),
    failure: { ...quota, reason: 'authentication' },
  })
  held = stepRoutePill(held, { kind: 'tick', now: deadline })
  assertEquals(
    routePillNote(routePill(rewritten, held)).text,
    'fleet blocked on primary: an authentication failure · sign-in required',
  )
})

Deno.test('waiting again after settling starts without the old failure', () => {
  let held = stepRoutePill(waitedOn(waiting, quota), { kind: 'settled' })
  held = stepRoutePill(held, { kind: 'waiting', pin: routePin(waiting) })
  assertEquals(routePill(waiting, held).failure, null)
  assertEquals(
    routePillNote(routePill(waiting, held)).text,
    'Waiting on primary',
  )
})

Deno.test('a failure read for another pin is dropped', () => {
  const held = stepRoutePill(
    stepRoutePill(routePillHeld(start), {
      kind: 'waiting',
      pin: routePin(waiting),
    }),
    {
      kind: 'failure',
      pin: { ...routePin(waiting), epoch: '2' },
      failure: quota,
    },
  )
  assertEquals(routePill(waiting, held).failure, null)
})

Deno.test('the failure is read again for a rewrite and for a reconnect, never while pinned', () => {
  const first = routeFailureKey(waiting, 'live')
  assertNotEquals(first, null)
  assertNotEquals(
    routeFailureKey({ ...waiting, failureRevision: 'other' }, 'live'),
    first,
  )
  assertNotEquals(routeFailureKey(waiting, 'reconnecting'), first)
  assertEquals(routeFailureKey(waiting, 'live'), first)
  assertEquals(routeFailureKey(pinned, 'live'), null)
})

Deno.test('a failed first read leaves the waiting note until a reconnect reads it', () => {
  let held = stepRoutePill(routePillHeld(start), {
    kind: 'waiting',
    pin: routePin(waiting),
  })
  assertEquals(
    routePillNote(routePill(waiting, held)).text,
    'Waiting on primary',
  )
  held = stepRoutePill(held, {
    kind: 'failure',
    pin: routePin(waiting),
    failure: quota,
  })
  assertEquals(routePillNote(routePill(waiting, held)).stage, 'waiting')
  assertEquals(routePill(waiting, held).failure?.deadline, deadline)
})
