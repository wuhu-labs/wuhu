import {
  composerAim,
  dockAfter,
  pageTarget,
  targetKey,
} from './composer-target.ts'
import type { SessionCapability } from './session-capability.ts'

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
