import {
  composerAim,
  dockAfter,
  pageTarget,
  targetKey,
} from './composer-target.ts'
import {
  type SessionCapability,
  sessionCapability,
} from './session-capability.ts'
import { conversationCapability } from './use-conversation-access.ts'

function equal(actual: unknown, expected: unknown) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    )
  }
}

const agent: SessionCapability = { kind: 'agent' }
const task: SessionCapability = { kind: 'task' }
const unknown: SessionCapability = { kind: 'unknown' }
const archived: SessionCapability = { kind: 'archived' }
const box = (id: string) => ({ kind: 'session' as const, id })

Deno.test('only an agent box or an allowed conversation is a page target', () => {
  equal(pageTarget(box('a'), null, agent), box('a'))
  equal(pageTarget(box('a'), 'transcript', agent), null)
  equal(pageTarget(box('a'), 'context', agent), null)
  equal(pageTarget(box('t'), null, task), null)
  equal(pageTarget(box('x'), null, unknown), null)
  equal(pageTarget(box('z'), null, archived), null)
  const conversation = { kind: 'conversation' as const, id: 'c' }
  equal(
    pageTarget(conversation, null, { kind: 'conversation', allowed: true }),
    conversation,
  )
  equal(
    pageTarget(conversation, null, { kind: 'conversation', allowed: false }),
    null,
  )
  equal(pageTarget({ kind: 'path', path: '/a.md' }, null, unknown), null)
})

Deno.test('person–session DMs have no composer regardless of roster or member order', () => {
  const person = { member: 'owner', kind: 'user' }
  const session = { member: 'a', kind: 'session' }
  const conversation = { kind: 'conversation' as const, id: 'dm' }
  const rosters: Parameters<typeof conversationCapability>[1][] = [
    null,
    [],
    ...[
      { kind: 'agent', lifecycle: 'live' },
      { kind: 'task', lifecycle: 'live' },
      { kind: 'agent', lifecycle: 'archived' },
    ].map((record) =>
      [{ id: 'a', ...record }] as NonNullable<
        Parameters<typeof conversationCapability>[1]
      >
    ),
  ]
  for (const members of [[person, session], [session, person]]) {
    for (const roster of rosters) {
      const capability = conversationCapability(
        { kind: 'dm_user', members },
        roster,
      )
      equal(capability, { kind: 'conversation', allowed: false })
      const page = pageTarget(conversation, null, capability)
      equal(page, null)
      equal(
        composerAim({
          page,
          dock: null,
          dockCapability: unknown,
          compact: false,
        }),
        null,
      )
      equal(
        composerAim({ page, dock: 'a', dockCapability: agent, compact: false }),
        { target: box('a'), docked: true },
      )
    }
  }
})

Deno.test('person–person DMs, groups, session DMs and agent boxes keep their composer', () => {
  const person = { member: 'owner', kind: 'user' }
  const otherPerson = { member: 'peer', kind: 'user' }
  const session = { member: 'a', kind: 'session' }
  const roster = [
    { id: 'a', kind: 'agent', lifecycle: 'live' },
    { id: 'b', kind: 'agent', lifecycle: 'live' },
  ] as NonNullable<Parameters<typeof conversationCapability>[1]>
  const conversation = { kind: 'conversation' as const, id: 'c' }
  for (
    const record of [
      { kind: 'dm_user', members: [person, otherPerson] },
      { kind: 'users', members: [person, otherPerson] },
      { kind: 'users', members: [person, otherPerson, session] },
      {
        kind: 'dm_session',
        members: [session, { member: 'b', kind: 'session' }],
      },
    ] satisfies NonNullable<Parameters<typeof conversationCapability>[0]>[]
  ) {
    const page = pageTarget(
      conversation,
      null,
      conversationCapability(record, roster),
    )
    equal(page, conversation)
    equal(
      composerAim({
        page,
        dock: null,
        dockCapability: unknown,
        compact: false,
      }),
      { target: conversation, docked: false },
    )
  }
  equal(
    pageTarget(box('a'), null, sessionCapability(roster[0])),
    box('a'),
  )
})

Deno.test('box and users conversations with a session and user keep a cold-load composer', () => {
  const session = { member: 'a', kind: 'session' }
  const person = { member: 'owner', kind: 'user' }
  const roster = [{ id: 'a', kind: 'agent', lifecycle: 'live' }] as NonNullable<
    Parameters<typeof conversationCapability>[1]
  >
  for (const kind of ['box', 'users'] as const) {
    for (const members of [[session, person], [person, session]]) {
      const destination = {
        kind: 'conversation' as const,
        id: kind === 'box' ? 'a' : 'group',
      }
      const page = pageTarget(
        destination,
        null,
        conversationCapability({ kind, members }, roster),
      )
      equal(page, destination)
      for (const compact of [false, true]) {
        equal(
          composerAim({ page, dock: null, dockCapability: unknown, compact }),
          { target: destination, docked: false },
        )
      }
    }
  }
})

Deno.test('the dock moves only when an agent box opens', () => {
  equal(dockAfter(null, box('a')), 'a')
  equal(dockAfter('a', box('b')), 'b')
  equal(dockAfter('a', null), 'a')
  equal(dockAfter('a', { kind: 'conversation', id: 'c' }), 'a')
})

Deno.test('off its page the dock names its agent, on desktop only', () => {
  equal(
    composerAim({
      page: null,
      dock: 'a',
      dockCapability: agent,
      compact: false,
    }),
    { target: box('a'), docked: true },
  )
  equal(
    composerAim({
      page: null,
      dock: 'a',
      dockCapability: agent,
      compact: true,
    }),
    null,
  )
  equal(
    composerAim({
      page: box('b'),
      dock: 'a',
      dockCapability: agent,
      compact: false,
    }),
    { target: box('b'), docked: false },
  )
})

Deno.test('a dock whose agent can no longer take input goes away', () => {
  for (const capability of [archived, unknown, task]) {
    equal(
      composerAim({
        page: null,
        dock: 'a',
        dockCapability: capability,
        compact: false,
      }),
      null,
    )
  }
  equal(
    composerAim({
      page: null,
      dock: null,
      dockCapability: unknown,
      compact: false,
    }),
    null,
  )
})

Deno.test('a draft is keyed by its target kind and id', () => {
  equal(targetKey(box('a')), 'session:a')
  equal(targetKey({ kind: 'conversation', id: 'a' }), 'conversation:a')
})
