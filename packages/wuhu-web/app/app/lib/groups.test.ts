import { directoryOf } from './directory.ts'
import {
  groupLabel,
  memberGroups,
  memberOr,
  senderGroupLabel,
} from './groups.ts'

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

Deno.test('a view outside the member groups creates in Shared', () => {
  assertEquals(
    memberOr('lamp-oak-fern', ['shared', 'lamp-oak-fern']),
    'lamp-oak-fern',
  )
  assertEquals(
    memberOr('moss-kite-drum', ['shared', 'lamp-oak-fern']),
    'shared',
  )
  assertEquals(memberOr('moss-kite-drum', null), 'moss-kite-drum')
})

Deno.test('Shared is Shared; a personal group is its person', () => {
  assertEquals(groupLabel('shared', people), 'Shared')
  assertEquals(groupLabel('lamp-oak-fern', people), 'Minsheng')
  assertEquals(groupLabel('moss-kite-drum', people), 'moss-kite-drum')
})

Deno.test('only a sender from another group gets a label', () => {
  assertEquals(senderGroupLabel('shared', 'shared', people), null)
  assertEquals(senderGroupLabel(undefined, 'shared', people), null)
  assertEquals(senderGroupLabel('lamp-oak-fern', 'shared', people), 'Minsheng')
  assertEquals(senderGroupLabel('shared', 'lamp-oak-fern', people), 'Shared')
})
