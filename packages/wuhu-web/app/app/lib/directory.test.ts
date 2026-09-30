import {
  directoryOf,
  displayFor,
  displayNameFor,
  handleFor,
  initialsFrom,
  initialsOf,
  memberHandle,
  memberName,
  principalName,
  senderName,
  sessionTitlesOf,
} from './directory.ts'

function assertEquals<T>(actual: T, expected: T): void {
  if (actual !== expected) {
    throw new Error(`expected ${String(expected)}, got ${String(actual)}`)
  }
}

const directory = directoryOf([
  { id: 'sail-clock-pepper', handle: 'alice', displayName: 'Alice Chen' },
  { id: 'reed-moth-anvil', handle: null },
  { id: 'flint-vane-yarn', handle: '' },
  { id: 'owner' },
  { id: 'mango-wheat-pencil', displayName: 'Morgan Lee' },
])

Deno.test('the directory retains users with or without profile fields', () => {
  assertEquals(handleFor(directory, 'sail-clock-pepper'), 'alice')
  assertEquals(handleFor(directory, 'reed-moth-anvil'), undefined)
  assertEquals(handleFor(directory, 'flint-vane-yarn'), undefined)
  assertEquals(handleFor(directory, 'owner'), undefined)
})

Deno.test('a display name enters without a handle', () => {
  assertEquals(displayNameFor(directory, 'mango-wheat-pencil'), 'Morgan Lee')
  assertEquals(handleFor(directory, 'mango-wheat-pencil'), undefined)
  assertEquals(displayNameFor(directory, 'reed-moth-anvil'), undefined)
})

Deno.test('a known principal renders as its display name', () => {
  assertEquals(displayFor(directory, 'sail-clock-pepper'), 'Alice Chen')
})

Deno.test('an unknown principal renders as itself', () => {
  assertEquals(displayFor(directory, 'reed-moth-anvil'), 'reed-moth-anvil')
  assertEquals(displayFor(directory, 'nobody'), 'nobody')
})

Deno.test('a display name alone labels a person', () => {
  assertEquals(
    displayFor(directory, 'mango-wheat-pencil'),
    'Morgan Lee',
  )
})

Deno.test('the directory wins over a stale payload handle', () => {
  assertEquals(
    displayFor(directory, 'sail-clock-pepper', 'renamed'),
    'Alice Chen',
  )
})

Deno.test('a payload without a handle falls back to the directory', () => {
  assertEquals(
    senderName(directory, { sender: 'sail-clock-pepper' }),
    'Alice Chen',
  )
  assertEquals(
    senderName(directory, { sender: 'sail-clock-pepper', senderHandle: null }),
    'Alice Chen',
  )
  assertEquals(
    senderName(directory, { sender: 'reed-moth-anvil' }),
    'reed-moth-anvil',
  )
})

Deno.test('members resolve through their own sibling', () => {
  assertEquals(
    memberName(
      directory,
      { member: 'reed-moth-anvil', memberHandle: 'bob' },
      sessions,
    ),
    'reed-moth-anvil',
  )
  assertEquals(
    memberName(directory, { member: 'sail-clock-pepper' }, sessions),
    'Alice Chen',
  )
})

Deno.test('initials take the first letters of the first two words', () => {
  assertEquals(initialsFrom('Morgan Lee'), 'ML')
  assertEquals(initialsFrom('mango-wheat-pencil'), 'MW')
  assertEquals(initialsFrom('alice'), 'AL')
  assertEquals(initialsFrom(''), '')
})

Deno.test('a principal initials through its best known name', () => {
  assertEquals(initialsOf(directory, 'sail-clock-pepper'), 'AC')
  assertEquals(initialsOf(directory, 'mango-wheat-pencil'), 'ML')
  assertEquals(initialsOf(directory, 'reed-moth-anvil'), 'RM')
})

const sessions = sessionTitlesOf([
  { id: 'lamp-muffin-panda', group: 'shared', title: 'Product Researcher' },
  { id: 'fresh-new-session', group: 'shared', title: '' },
])

Deno.test('a session sender shows its title, never a user lookup', () => {
  const alias = directoryOf([{ id: 'lamp-muffin-panda', handle: 'impostor' }])
  assertEquals(
    senderName(
      alias,
      { sender: 'lamp-muffin-panda', senderKind: 'session' },
      sessions,
    ),
    'Product Researcher',
  )
  assertEquals(
    senderName(
      alias,
      { sender: 'fresh-new-session', senderKind: 'session' },
      sessions,
    ),
    'fresh-new-session',
  )
})

Deno.test('a user sender shows its display name', () => {
  assertEquals(
    senderName(
      directory,
      { sender: 'sail-clock-pepper', senderKind: 'user' },
      sessions,
    ),
    'Alice Chen',
  )
})

Deno.test('a creator resolves as a session before a user', () => {
  assertEquals(
    principalName(directory, sessions, 'lamp-muffin-panda'),
    'Product Researcher',
  )
  assertEquals(
    principalName(directory, sessions, 'sail-clock-pepper'),
    'Alice Chen',
  )
})

Deno.test('an untitled session is still never looked up as a user', () => {
  const alias = directoryOf([{ id: 'fresh-new-session', handle: 'impostor' }])
  assertEquals(
    principalName(alias, sessions, 'fresh-new-session'),
    'fresh-new-session',
  )
  assertEquals(
    senderName(alias, { sender: 'fresh-new-session' }, sessions),
    'fresh-new-session',
  )
})

Deno.test('blank names fall back to handle, then id', () => {
  const people = directoryOf([
    { id: 'named', displayName: '  Vivian Cao  ', handle: 'viviancao330' },
    { id: 'handled', displayName: ' \n ', handle: 'vivian' },
    { id: 'bare', displayName: '  ', handle: null },
  ])
  assertEquals(displayFor(people, 'named'), 'Vivian Cao')
  assertEquals(displayFor(people, 'handled'), '@vivian')
  assertEquals(displayFor(people, 'bare', 'stale'), 'bare')
  assertEquals(displayFor(people, 'unknown', 'payload'), '@payload')
  assertEquals(
    memberHandle(people, { member: 'named' }, sessions),
    '@viviancao330',
  )
  assertEquals(memberHandle(people, { member: 'handled' }, sessions), undefined)
})

Deno.test('agent members use titles or ids, never people or handles', () => {
  const alias = directoryOf([
    { id: 'fresh-new-session', displayName: 'Impostor', handle: 'impostor' },
  ])
  assertEquals(
    memberName(
      alias,
      { member: 'lamp-muffin-panda', kind: 'session' },
      sessions,
    ),
    'Product Researcher',
  )
  assertEquals(
    memberName(alias, { member: 'fresh-new-session' }, sessions),
    'fresh-new-session',
  )
  assertEquals(
    memberName(alias, {
      member: 'unknown-agent',
      kind: 'session',
      memberHandle: 'wrong',
    }, sessions),
    'unknown-agent',
  )
  assertEquals(
    memberHandle(alias, { member: 'fresh-new-session' }, sessions),
    undefined,
  )
})

Deno.test('the central resolver separates known sessions from people', () => {
  const people = directoryOf([{
    id: 'fresh-new-session',
    handle: 'impostor',
    displayName: 'Wrong Person',
  }])
  assertEquals(
    displayFor(people, 'fresh-new-session', null, sessions),
    'fresh-new-session',
  )
  assertEquals(
    displayFor(people, 'fresh-new-session', null, sessions, 'user'),
    'Wrong Person',
  )
})

Deno.test('a display name equal to the marked handle does not repeat it', () => {
  const people = directoryOf([{
    id: 'person',
    handle: 'vivian',
    displayName: '@vivian',
  }])
  assertEquals(
    memberHandle(people, { member: 'person', kind: 'user' }, sessions),
    undefined,
  )
})
