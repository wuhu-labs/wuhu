import {
  directoryOf,
  displayFor,
  displayNameFor,
  handleFor,
  initialsFrom,
  initialsOf,
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

Deno.test('only a named user enters the directory', () => {
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

Deno.test('a known principal renders as its marked handle', () => {
  assertEquals(displayFor(directory, 'sail-clock-pepper'), '@alice')
})

Deno.test('an unknown principal renders as itself', () => {
  assertEquals(displayFor(directory, 'reed-moth-anvil'), 'reed-moth-anvil')
  assertEquals(displayFor(directory, 'nobody'), 'nobody')
})

Deno.test('a display name alone does not become a handle', () => {
  assertEquals(
    displayFor(directory, 'mango-wheat-pencil'),
    'mango-wheat-pencil',
  )
})

Deno.test('a payload handle wins over the directory', () => {
  assertEquals(
    displayFor(directory, 'sail-clock-pepper', 'renamed'),
    '@renamed',
  )
})

Deno.test('a payload without a handle falls back to the directory', () => {
  assertEquals(
    senderName(directory, { sender: 'sail-clock-pepper' }),
    '@alice',
  )
  assertEquals(
    senderName(directory, { sender: 'sail-clock-pepper', senderHandle: null }),
    '@alice',
  )
  assertEquals(
    senderName(directory, { sender: 'reed-moth-anvil' }),
    'reed-moth-anvil',
  )
})

Deno.test('members resolve through their own sibling', () => {
  assertEquals(
    memberName(directory, { member: 'reed-moth-anvil', memberHandle: 'bob' }),
    '@bob',
  )
  assertEquals(
    memberName(directory, { member: 'sail-clock-pepper' }),
    '@alice',
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

Deno.test('a user sender keeps its handle', () => {
  assertEquals(
    senderName(
      directory,
      { sender: 'sail-clock-pepper', senderKind: 'user' },
      sessions,
    ),
    '@alice',
  )
})

Deno.test('a creator resolves as a session before a user', () => {
  assertEquals(
    principalName(directory, sessions, 'lamp-muffin-panda'),
    'Product Researcher',
  )
  assertEquals(
    principalName(directory, sessions, 'sail-clock-pepper'),
    '@alice',
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
