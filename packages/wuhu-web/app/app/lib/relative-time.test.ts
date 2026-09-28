import { relativeSpan, relativeTime } from './relative-time.ts'

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

const now = new Date('2026-08-09T12:00:00Z')

Deno.test('recent moments and short spans', () => {
  assertEquals(relativeTime('2026-08-09T11:59:40Z', now), 'just now')
  assertEquals(relativeTime('2026-08-09T11:15:00Z', now), '45m ago')
  assertEquals(relativeTime('2026-08-09T05:00:00Z', now), '7h ago')
  assertEquals(relativeTime('2026-08-06T12:00:00Z', now), '3d ago')
})

Deno.test('older activity falls back to a date', () => {
  const sameYear = relativeTime('2026-07-15T12:00:00Z', now)
  if (!/15/.test(sameYear) || /2026/.test(sameYear)) {
    throw new Error(`unexpected same-year date: ${sameYear}`)
  }
  const otherYear = relativeTime('2025-12-30T12:00:00Z', now)
  if (!/2025/.test(otherYear)) {
    throw new Error(`expected the year in ${otherYear}`)
  }
})

Deno.test('garbage input passes through', () => {
  assertEquals(relativeTime('not-a-date', now), 'not-a-date')
})

Deno.test('a span reads forward or back from now', () => {
  assertEquals(
    relativeSpan(new Date('2026-08-09T14:40:00Z'), now),
    'in 3 hours',
  )
  assertEquals(
    relativeSpan(new Date('2026-08-09T11:35:00Z'), now),
    '25 minutes ago',
  )
  assertEquals(
    relativeSpan(new Date('2026-08-12T12:00:00Z'), now),
    'in 3 days',
  )
  assertEquals(
    relativeSpan(new Date('2026-08-09T12:00:20Z'), now),
    'this minute',
  )
})
