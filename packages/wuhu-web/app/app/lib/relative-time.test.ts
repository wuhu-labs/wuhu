import { relativeSpan } from './relative-time.ts'

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

const now = new Date('2026-08-09T12:00:00Z')

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
