import { assertEquals } from 'jsr:@std/assert@1'
import {
  composerAim,
  dockAfter,
  pageTarget,
  targetKey,
} from './composer-target.ts'
import type { SessionCapability } from './session-capability.ts'

const agent: SessionCapability = { kind: 'agent' }
const task: SessionCapability = { kind: 'task' }
const archived: SessionCapability = { kind: 'archived' }
const box = (id: string) => ({ kind: 'session' as const, id })
const conversation = { kind: 'conversation' as const, id: 'c' }
const page = { kind: 'path' as const, path: '/notes/plan.md' }

Deno.test('only an agent box or an allowed conversation is a page target', () => {
  assertEquals(pageTarget(box('a'), agent), box('a'))
  assertEquals(pageTarget(box('t'), task), null)
  assertEquals(pageTarget(box('z'), archived), null)
  assertEquals(pageTarget(box('x'), { kind: 'unknown' }), null)
  assertEquals(
    pageTarget(conversation, { kind: 'conversation', allowed: true }),
    conversation,
  )
  assertEquals(
    pageTarget(conversation, { kind: 'conversation', allowed: false }),
    null,
  )
  assertEquals(pageTarget(page, agent), null)
})

Deno.test('only an agent box moves the dock', () => {
  assertEquals(dockAfter(null, box('a')), 'a')
  assertEquals(dockAfter('a', conversation), 'a')
  assertEquals(dockAfter('a', null), 'a')
})

Deno.test('a session page posts to itself or not at all; a page asks the dock', () => {
  assertEquals(
    composerAim({ destination: box('a'), page: box('a'), dock: 'b' }),
    { target: box('a'), docked: false },
  )
  assertEquals(
    composerAim({ destination: box('t'), page: null, dock: 'b' }),
    null,
  )
  assertEquals(composerAim({ destination: page, page: null, dock: 'b' }), {
    target: box('b'),
    docked: true,
  })
  assertEquals(composerAim({ destination: page, page: null, dock: null }), null)
  assertEquals(targetKey(box('a')), 'session:a')
})
