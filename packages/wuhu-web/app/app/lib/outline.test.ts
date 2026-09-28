import {
  ancestors,
  type Branch,
  flatten,
  nest,
  type Parented,
  stableOrder,
} from './outline.ts'

function equal<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

type Shape = [string, Shape[]]

function shape(branches: Branch<Parented>[]): Shape[] {
  return branches.map((branch) => [branch.item.id, shape(branch.children)])
}

const s = (id: string, parent: string | null = null) => ({ id, parent })

Deno.test('agent, child agent, task and grandchild nest at every depth', () => {
  equal(
    shape(nest([
      s('root'),
      s('child', 'root'),
      s('task', 'child'),
      s('grandchild', 'task'),
    ])),
    [['root', [['child', [['task', [['grandchild', []]]]]]]]],
  )
})

Deno.test('a session whose parent is filtered out becomes a root with its descendants', () => {
  equal(
    shape(nest([s('task', 'archived-agent'), s('subtask', 'task')])),
    [['task', [['subtask', []]]]],
  )
})

Deno.test('siblings and roots keep the incoming order', () => {
  equal(
    shape(nest([s('b'), s('a'), s('b2', 'b'), s('b1', 'b')])),
    [['b', [['b2', []], ['b1', []]]], ['a', []]],
  )
})

Deno.test('a parent cycle is cut at its first member and nothing is lost', () => {
  equal(
    shape(nest([s('x', 'y'), s('y', 'x'), s('z')])),
    [['z', []], ['x', [['y', []]]]],
  )
})

Deno.test('flatten descends only into open branches and reports depth', () => {
  const tree = nest([s('a'), s('b', 'a'), s('c', 'b'), s('d')])
  equal(
    flatten(tree, (id) => id === 'a').map((row) => [
      row.item.id,
      row.depth,
      row.hasChildren,
      row.open,
    ]),
    [['a', 0, true, true], ['b', 1, true, false], ['d', 0, false, false]],
  )
})

Deno.test('ancestors walk the parent chain and stop at a cycle', () => {
  equal(
    ancestors([s('a'), s('b', 'a'), s('c', 'b')], 'c'),
    ['b', 'a'],
  )
  equal(ancestors([s('x', 'y'), s('y', 'x')], 'x'), ['y', 'x'])
  equal(ancestors([s('orphan', 'gone')], 'orphan'), [])
})

Deno.test('stable order keeps drawn rows in place and appends newcomers', () => {
  equal(
    stableOrder([s('c'), s('a'), s('new')], ['a', 'gone', 'c']).map((x) =>
      x.id
    ),
    ['a', 'c', 'new'],
  )
})
