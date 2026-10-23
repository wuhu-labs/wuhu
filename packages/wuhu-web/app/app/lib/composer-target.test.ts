import { assertEquals } from 'jsr:@std/assert@1'
import {
  composerAim,
  keepRecents,
  keptRecents,
  pageTarget,
  pickTarget,
  recentTargets,
  reconcileTargeting,
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

Deno.test('a session page keeps its own target; a task stays read-only', () => {
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

Deno.test('recent targets are most-recent first, unique and bounded like the Mac dock', () => {
  assertEquals(recentTargets(['a', 'b', 'c'], 'b'), ['b', 'a', 'c'])
  assertEquals(recentTargets(['1', '2', '3', '4', '5', '6', '7', '8'], '9'), [
    '9',
    '1',
    '2',
    '3',
    '4',
    '5',
    '6',
    '7',
  ])
  assertEquals(
    composerAim({ destination: conversation, page: conversation, dock: 'b' }),
    { target: conversation, docked: false },
  )
  assertEquals(
    composerAim({ destination: box('a'), page: box('a'), dock: 'a' }),
    { target: box('a'), docked: false },
  )
})

Deno.test('target machine follows page activation, doc picks and archived fallback', () => {
  const initial = { page: null, dock: null, recents: [] }
  const opened = reconcileTargeting(initial, box('a'), ['a', 'b'], 'b')
  assertEquals(opened, { page: 'session:a', dock: 'a', recents: ['a'] })
  const document = reconcileTargeting(opened, null, ['a', 'b'], 'b')
  const picked = pickTarget(document, 'b')
  assertEquals(picked.recents, ['b', 'a'])
  assertEquals(reconcileTargeting(picked, null, ['a', 'b'], 'a'), picked)
  assertEquals(reconcileTargeting(picked, box('a'), ['a', 'b'], 'b'), {
    page: 'session:a',
    dock: 'a',
    recents: ['a', 'b'],
  })
  assertEquals(reconcileTargeting(picked, box('a'), ['a'], 'a'), opened)
  assertEquals(reconcileTargeting(picked, null, ['a'], 'a'), {
    page: null,
    dock: 'a',
    recents: ['a'],
  })
  assertEquals(reconcileTargeting(picked, null, [], null), {
    page: null,
    dock: null,
    recents: [],
  })
})

Deno.test('recent storage tolerates malformed JSON, deduplicates, bounds and purges', () => {
  const values = new Map<string, string>()
  const original = Object.getOwnPropertyDescriptor(globalThis, 'localStorage')
  Object.defineProperty(globalThis, 'localStorage', {
    configurable: true,
    value: {
      getItem: (key: string) => values.get(key) ?? null,
      setItem: (key: string, value: string) => values.set(key, value),
    },
  })
  try {
    assertEquals(keptRecents(null), [])
    for (const bad of ['{', '{}', 'null']) {
      values.set('wuhu:dock-recents:test', bad)
      assertEquals(keptRecents('test'), [])
    }
    values.set(
      'wuhu:dock-recents:test',
      JSON.stringify(['a', 'a', 2, 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i']),
    )
    assertEquals(keptRecents('test'), ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'])
    keepRecents('test', ['b'])
    assertEquals(keptRecents('test'), ['b'])
    keepRecents('test', [])
    assertEquals(keptRecents('test'), [])
    keepRecents(null, ['ignored'])
  } finally {
    if (original) Object.defineProperty(globalThis, 'localStorage', original)
    else Reflect.deleteProperty(globalThis, 'localStorage')
  }
})

Deno.test('opening a task or archived row and returning preserves the document pick', () => {
  const picked = pickTarget(
    { page: null, dock: 'oldest', recents: ['oldest'] },
    'backend',
  )
  for (const capability of [task, archived]) {
    const noBox = pageTarget(box('not-an-agent-box'), capability)
    const onRow = reconcileTargeting(
      picked,
      noBox,
      ['oldest', 'backend'],
      'oldest',
    )
    const backOnDocument = reconcileTargeting(onRow, null, [
      'oldest',
      'backend',
    ], 'oldest')
    assertEquals(backOnDocument.dock, 'backend')
    assertEquals(backOnDocument.recents, ['backend', 'oldest'])
  }
})
