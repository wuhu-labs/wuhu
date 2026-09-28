import type { EntryKind, MutationEvent } from './contract.gen.ts'
import { applyEvent, buildTree, type PathMap } from './tree.ts'

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

function paths(entries: [string, EntryKind][]): PathMap {
  return new Map(entries)
}

Deno.test('buildTree nests children and sorts directories first, then by name', () => {
  const tree = buildTree(
    paths([
      ['/src', 'directory'],
      ['/src/main.ts', 'file'],
      ['/src/lib', 'directory'],
      ['/readme.md', 'file'],
    ]),
  )
  assertEquals(tree.map((node) => node.name), ['src', 'readme.md'])
  assertEquals(tree[0]!.children.map((node) => node.name), ['lib', 'main.ts'])
})

Deno.test('buildTree infers missing parents as directories', () => {
  const tree = buildTree(paths([['/a/b/c.txt', 'file']]))
  assertEquals(tree.length, 1)
  assertEquals(tree[0]!.name, 'a')
  assertEquals(tree[0]!.kind, 'directory')
  assertEquals(tree[0]!.children[0]!.children[0]!.name, 'c.txt')
})

Deno.test('applyEvent write and delete', () => {
  let map: PathMap = new Map()
  map = applyEvent(map, { kind: 'write', path: '/x', rev: 1, entry: 'file' })
  assertEquals(map.get('/x'), 'file')
  map = applyEvent(map, { kind: 'write', path: '/x/y', rev: 2, entry: 'file' })
  map = applyEvent(
    map,
    { kind: 'delete', path: '/x', rev: 3 } as MutationEvent,
  )
  assertEquals(map.has('/x'), false)
  assertEquals(map.has('/x/y'), false)
})

Deno.test('applyEvent move relocates the whole subtree', () => {
  let map: PathMap = paths([
    ['/old', 'directory'],
    ['/old/a.txt', 'file'],
    ['/old/sub', 'directory'],
    ['/old/sub/b.txt', 'file'],
  ])
  map = applyEvent(map, {
    kind: 'move',
    path: '/old',
    to: '/new',
    rev: 4,
    entry: 'directory',
  })
  assertEquals([...map.keys()].sort(), [
    '/new',
    '/new/a.txt',
    '/new/sub',
    '/new/sub/b.txt',
  ])
})

Deno.test('applyEvent is idempotent for a repeated write and move', () => {
  const write: MutationEvent = {
    kind: 'write',
    path: '/p',
    rev: 1,
    entry: 'file',
  }
  const once = applyEvent(new Map(), write)
  const twice = applyEvent(once, write)
  assertEquals([...twice.entries()], [...once.entries()])

  const move: MutationEvent = {
    kind: 'move',
    path: '/p',
    to: '/q',
    rev: 2,
    entry: 'file',
  }
  const moved = applyEvent(once, move)
  const movedAgain = applyEvent(moved, move)
  assertEquals([...movedAgain.entries()], [...moved.entries()])
})
