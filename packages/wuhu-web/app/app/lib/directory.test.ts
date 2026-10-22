import {
  directoryOf,
  displayFor,
  displayNameFor,
  handleFor,
  initialsFrom,
  initialsOf,
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
