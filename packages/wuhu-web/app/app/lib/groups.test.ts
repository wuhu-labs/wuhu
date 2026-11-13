import { groupLabel, memberGroups } from './groups.ts'

function assertEquals(actual: unknown, expected: unknown): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

Deno.test('member groups list Shared first, then the server order', () => {
  assertEquals(
    memberGroups([
      { id: 'lamp-oak-fern', member: true, readable: true },
      { id: 'moss-kite-drum', member: false, readable: true },
      { id: 'shared', member: true, readable: true },
    ]),
    ['shared', 'lamp-oak-fern'],
  )
})

Deno.test('Shared is Shared; other groups keep their identity', () => {
  assertEquals(groupLabel('shared'), 'Shared')
  assertEquals(groupLabel('lamp-oak-fern'), 'lamp-oak-fern')
  assertEquals(groupLabel('moss-kite-drum'), 'moss-kite-drum')
})
