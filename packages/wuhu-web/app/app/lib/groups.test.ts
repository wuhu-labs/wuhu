import { directoryOf } from './directory.ts'
import { groupLabel, memberGroups } from './groups.ts'

function assertEquals(actual: unknown, expected: unknown): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

const people = directoryOf([
  { id: 'lamp-oak-fern', handle: 'minsheng', displayName: 'Minsheng' },
])

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

Deno.test('Shared is Shared; a personal group is its person', () => {
  assertEquals(groupLabel('shared', people), 'Shared')
  assertEquals(groupLabel('lamp-oak-fern', people), 'Minsheng')
  assertEquals(groupLabel('moss-kite-drum', people), 'moss-kite-drum')
})
