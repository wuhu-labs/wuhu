import {
  rowTarget,
  sidebarFile,
  sidebarNodes,
  sidebarPaths,
  validDestination,
} from './sidebars.ts'
import type { PathMap } from './tree.ts'

function equal(actual: unknown, expected: unknown) {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

function refused(run: () => unknown): string {
  try {
    run()
  } catch (failure) {
    return (failure as Error).message
  }
  throw new Error('expected a refusal')
}

const output = (rows: unknown[][], order = 'sort_order') => ({
  columns: ['id', 'parent_id', 'title', 'destination', order],
  rows,
})

Deno.test('definitions live directly under /.sidebars as json files, sorted', () => {
  const paths: PathMap = new Map([
    ['/.sidebars', 'directory'],
    ['/.sidebars/work.json', 'file'],
    ['/.sidebars/agents.json', 'file'],
    ['/.sidebars/notes.md', 'file'],
    ['/.sidebars/old', 'directory'],
    ['/.sidebars/old/x.json', 'file'],
    ['/sidebars.json', 'file'],
  ])
  equal(sidebarPaths(paths), ['/.sidebars/agents.json', '/.sidebars/work.json'])
})

Deno.test('a definition needs a title and unique, complete sections', () => {
  equal(
    sidebarFile(
      '/.sidebars/workshop.json',
      '{"title":"The Workshop","icon":"hammer","extra":1,"sections":[{"id":"docs","title":"Documents","sql":"SELECT * FROM docs"}]}',
    ),
    {
      path: '/.sidebars/workshop.json',
      title: 'The Workshop',
      sections: [{ id: 'docs', title: 'Documents', sql: 'SELECT * FROM docs' }],
    },
  )
  for (
    const content of [
      '{"title":"Broken","sections":[{"id":"same","title":"A","sql":"SELECT 1"},{"id":"same","title":"B","sql":"SELECT 2"}]}',
      '{"title":" ","sections":[]}',
      '{"title":"No sql","sections":[{"id":"a","title":"A","sql":"  "}]}',
      '{"title":"Null section","sections":[null]}',
      '{"title":"No sections"}',
      '{"title":"Icon","icon":3,"sections":[]}',
      'null',
      'not json',
    ]
  ) {
    equal(sidebarFile('/.sidebars/broken.json', content), {
      path: '/.sidebars/broken.json',
      title: 'broken',
      failure: 'broken is not a readable sidebar definition.',
    })
  }
})

Deno.test('document, session, conversation and chat destinations are kept; others refused', () => {
  const nodes = sidebarNodes(output([
    ['doc', null, 'Observation', '/demo/observations/2026-09-14.md', 0],
    ['agent', null, 'Agent', '/_/sessions/donkey-kitten-valley', 1],
    ['dm', null, 'DM', '/_/conversations/0199a0d6', 1],
    ['chat', null, 'Conversation', 'chat', 2],
  ]))
  equal(nodes.map((node) => node.destination), [
    '/demo/observations/2026-09-14.md',
    '/_/sessions/donkey-kitten-valley',
    '/_/conversations/0199a0d6',
    'chat',
  ])
  for (
    const invalid of [
      'https://example.com',
      '../doc',
      '/a/../b',
      '/a//b',
      '/a#b',
      '/a/',
      'agent:se_1',
      '/_/sessions',
      '/_/sessions/a/AGENTS.md',
      '/_/login',
      '/a%20b',
    ]
  ) {
    if (validDestination(invalid)) throw new Error(`${invalid} accepted`)
  }
})

Deno.test('duplicate ids, missing parents and cycles refuse the section', () => {
  for (
    const rows of [
      [['a', null, 'A', '/a', 0], ['a', null, 'B', '/b', 1]],
      [['a', 'b', 'A', '/a', 0], ['b', 'a', 'B', '/b', 1]],
      [['a', 'missing', 'A', '/a', 0]],
      [['a', 'a', 'A', '/a', 0]],
      [['a', '', 'A', '/a', 0]],
      [['a', null, 'A', '/nowhere/', 0]],
    ]
  ) {
    refused(() => sidebarNodes(output(rows)))
  }
  equal(
    refused(() =>
      sidebarNodes({ columns: ['id', 'title', 'destination'], rows: [] })
    ),
    'The section query needs unique id, parent_id, title, and destination columns.',
  )
})

Deno.test('rows order by sort_order or order, then id; ordering is optional', () => {
  equal(
    sidebarNodes(output([
      ['z', null, 'Z', '/z', 3],
      ['b', null, 'B', '/b', 1],
      ['a', null, 'A', '/a', 1],
      ['first', null, 'First', '/first', -0.5],
    ], 'order')).map((node) => node.id),
    ['first', 'a', 'b', 'z'],
  )
  equal(
    sidebarNodes({
      columns: ['id', 'parent_id', 'title', 'destination'],
      rows: [['b', null, 'B', '/b'], ['a', null, 'A', '/a']],
    }).map((node) => node.id),
    ['a', 'b'],
  )
  refused(() => sidebarNodes(output([['a', null, 'A', '/a', 'first']])))
})

Deno.test('chat opens the first live agent and has no row without one', () => {
  equal(rowTarget('chat', 'scout', 'shared'), {
    kind: 'session',
    id: 'scout',
    href: '/_/sessions/scout',
  })
  equal(rowTarget('chat', null, 'shared'), null)
  equal(rowTarget('/_/conversations/c1', null, 'shared'), {
    kind: 'conversation',
    href: '/_/conversations/c1',
  })
  equal(rowTarget('/tasks.table', null, 'shared'), {
    kind: 'table',
    href: '/tasks.table',
  })
  equal(rowTarget('/notes/plan.md', null, 'shared'), {
    kind: 'document',
    href: '/notes/plan.md',
  })
  equal(rowTarget('chat', 'scout', 'sail-clock-pepper'), {
    kind: 'session',
    id: 'scout',
    href: '/_/sessions/scout?group=sail-clock-pepper',
  })
})
