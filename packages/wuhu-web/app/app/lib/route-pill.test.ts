import { assertEquals, assertNotEquals } from 'jsr:@std/assert@1'
import type { RouteFailure, SessionRoute } from './model-route.ts'
import {
  routeFailureKey,
  routePill,
  routePillNote,
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

Deno.test('a waiting pill turns blocked at its deadline', () => {
  let pill = routePill(waiting, start)
  pill = stepRoutePill(pill, { kind: 'failure', failure: quota })
  assertEquals(routePillNote(pill).stage, 'waiting')
  pill = stepRoutePill(pill, { kind: 'tick', now: deadline })
  assertEquals(routePillNote(pill).stage, 'blocked')
  assertEquals(routePillNote(pill).tone, 'rose')
})

Deno.test('a pill that stops waiting on the same pin reads recovered until the route moves', () => {
  let pill = stepRoutePill(routePill(waiting, start), {
    kind: 'failure',
    failure: quota,
  })
  pill = stepRoutePill(pill, { kind: 'route', route: pinned })
  assertEquals(routePillNote(pill), {
    stage: 'recovered',
    text: 'fleet → primary · recovered',
    tone: 'live',
  })
  assertEquals(pill.failure, null)
  pill = stepRoutePill(pill, {
    kind: 'route',
    route: { ...pinned, epoch: '4', member: 'backup', reason: 'compaction' },
  })
  assertEquals(routePillNote(pill).stage, 'pinned')
})

Deno.test('a new cause on the same waiting pin replaces the failure', () => {
  let pill = stepRoutePill(routePill(waiting, start), {
    kind: 'failure',
    failure: quota,
  })
  const rewritten = {
    ...waiting,
    failureRevision: '{"reason":"authentication"}',
  }
  pill = stepRoutePill(pill, { kind: 'route', route: rewritten })
  assertEquals(pill.failure, quota)
  pill = stepRoutePill(pill, {
    kind: 'failure',
    failure: { ...quota, reason: 'authentication' },
  })
  pill = stepRoutePill(pill, { kind: 'tick', now: deadline })
  assertEquals(
    routePillNote(pill).text,
    'fleet blocked on primary: an authentication failure · sign-in required',
  )
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
  let pill = routePill(waiting, start)
  assertEquals(routePillNote(pill).text, 'Waiting on primary')
  pill = stepRoutePill(pill, { kind: 'failure', failure: quota })
  assertEquals(routePillNote(pill).stage, 'waiting')
  assertEquals(pill.failure?.deadline, deadline)
})
