import { assertEquals } from 'jsr:@std/assert@1'
import { cardGroups, inCreationOrder, sessionStatusLine } from './cards.ts'

const item = (id: string, parent: string | null = null) => ({ id, parent })

Deno.test('a card holds one level of children; grandchildren are not drawn', () => {
  const groups = cardGroups([
    item('a'),
    item('b', 'a'),
    item('c', 'b'),
    item('d'),
  ])
  assertEquals(
    groups.map((group) => [group.item.id, group.children.map((c) => c.id)]),
    [['a', ['b']], ['d', []]],
  )
})

Deno.test('a child whose parent is gone is a card of its own', () => {
  assertEquals(cardGroups([item('b', 'gone')]).map((g) => g.item.id), ['b'])
})

Deno.test('cards stand oldest first, whatever their activity', () => {
  const born = (id: string, createdAt: string) => ({ id, createdAt })
  assertEquals(
    inCreationOrder([
      born('c', '2026-10-03T00:00:00Z'),
      born('a', '2026-10-01T00:00:00Z'),
      born('b', '2026-10-02T00:00:00Z'),
    ]).map((i) => i.id),
    ['a', 'b', 'c'],
  )
})

Deno.test('the status line names work, trouble and rest', () => {
  const base = {
    hold: 'none',
    work: 'idle',
    runState: 'no_run' as const,
    route: null,
  }
  assertEquals(sessionStatusLine(base), { tone: 'not', label: 'not working' })
  assertEquals(sessionStatusLine({ ...base, runState: 'tool' }), {
    tone: 'working',
    label: 'working',
  })
  assertEquals(sessionStatusLine({ ...base, hold: 'errored' }), {
    tone: 'trouble',
    label: 'errored',
  })
})
