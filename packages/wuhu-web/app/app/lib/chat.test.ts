import { assertEquals } from 'jsr:@std/assert@1'
import { chatItems, runGapMs, stampLabel } from './chat.ts'

const at = (day: number, minutes: number) => new Date(2026, 9, day, 9, minutes)

const entry = (key: string, sender: string, when: Date, own = false) => ({
  key,
  sender,
  own,
  at: when,
})

function shape(items: ReturnType<typeof chatItems>) {
  return items.map((item) =>
    item.kind === 'stamp'
      ? 'stamp'
      : item.entries.map((entry) => entry.key).join(',')
  )
}

Deno.test('a run holds one sender until someone else speaks', () => {
  const items = chatItems([
    entry('a', 'me', at(20, 0), true),
    entry('b', 'me', at(20, 1), true),
    entry('c', 'agent', at(20, 2)),
    entry('d', 'me', at(20, 3), true),
  ])
  assertEquals(shape(items), ['stamp', 'a,b', 'c', 'd'])
})

Deno.test('a gap over 15 minutes gets a stamp and ends the run', () => {
  const first = at(20, 0)
  const items = chatItems([
    entry('a', 'agent', first),
    entry('b', 'agent', new Date(first.getTime() + runGapMs)),
    entry('c', 'agent', new Date(first.getTime() + 2 * runGapMs + 1)),
  ])
  assertEquals(shape(items), ['stamp', 'a,b', 'stamp', 'c'])
})

Deno.test('a day change gets a stamp and ends the run', () => {
  const items = chatItems([
    entry('a', 'agent', new Date(2026, 9, 20, 23, 55)),
    entry('b', 'agent', new Date(2026, 9, 21, 0, 2)),
  ])
  assertEquals(shape(items), ['stamp', 'a', 'stamp', 'b'])
})

Deno.test('the stamp names the day, then the time', () => {
  const now = new Date(2026, 9, 22, 15, 0)
  assertEquals(stampLabel(new Date(2026, 9, 22, 20, 13), now), 'Today 20:13')
  assertEquals(stampLabel(new Date(2026, 9, 21, 9, 2), now), 'Yesterday 09:02')
  assertEquals(stampLabel(new Date(2026, 9, 14, 9, 2), now), 'Oct 14 09:02')
  assertEquals(
    stampLabel(new Date(2025, 11, 30, 18, 5), now),
    'Dec 30, 2025 18:05',
  )
})
