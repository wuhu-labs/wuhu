import { LoroDoc, LoroMap, LoroText, type LoroTreeNode } from 'loro-crdt/web'
import { configuredDoc, loadLoro } from '~/lib/wmd/loro.ts'
import { boardOf } from './board.ts'
import { demoDoc } from './demo.ts'

await loadLoro()

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

function board() {
  const doc = configuredDoc(new LoroDoc())
  const tree = doc.getTree('tree')
  tree.enableFractionalIndex(0)
  const node = (
    parent: LoroTreeNode | null,
    fields: Record<string, unknown>,
  ) => {
    const created = parent === null ? tree.createNode() : parent.createNode()
    for (const [key, value] of Object.entries(fields)) {
      created.data.set(key, value)
    }
    return created
  }
  return { doc, tree, node, connectors: doc.getMap('connectors') }
}

const frame = { x: 0, y: 0, w: 100, h: 50 }

Deno.test('reads items in tree order with their text marks', () => {
  const { doc, node } = board()
  const sticky = node(null, { id: 'a1k9z0', kind: 'sticky', ...frame })
  const text = sticky.data.setContainer('text', new LoroText())
  text.insert(0, 'Ship canvas v1')
  text.mark({ start: 12, end: 14 }, 'bold', true)
  const section = node(null, {
    id: 's3d8x1',
    kind: 'section',
    color: 'gray',
    ...frame,
  })
  node(section, { id: 'b2c4v6', kind: 'rect', color: 'blue', ...frame, x: 40 })
  node(null, { id: 'f9h1k2', kind: 'file', path: '/a.png', ...frame })
  doc.commit()
  const read = boardOf(doc)
  assertEquals(read.items.map((item) => [item.id, item.parent]), [
    ['a1k9z0', null],
    ['s3d8x1', null],
    ['b2c4v6', 's3d8x1'],
    ['f9h1k2', null],
  ])
  assertEquals(read.items[0].text, [
    { text: 'Ship canvas ' },
    { text: 'v1', bold: true },
  ])
  assertEquals(read.items[2].x, 40)
  assertEquals(read.items[3].path, '/a.png')
})

Deno.test('skips what is out of schema', () => {
  const { doc, node } = board()
  const sticky = node(null, { id: 'a00000', kind: 'sticky', ...frame })
  node(sticky, { id: 'a00001', kind: 'sticky', ...frame })
  const section = node(null, { id: 's00000', kind: 'section', ...frame })
  node(section, { id: 's00001', kind: 'section', ...frame })
  node(null, { id: 'k00000', kind: 'star', ...frame })
  node(null, { id: 'BAD', kind: 'sticky', ...frame })
  node(null, { id: 'w00000', kind: 'sticky', ...frame, w: '100' })
  node(null, { id: 'p00001', kind: 'file', ...frame })
  node(null, { id: 'p00002', kind: 'file', ...frame, path: 7 })
  node(null, { id: 'a00000', kind: 'rect', ...frame })
  doc.commit()
  assertEquals(boardOf(doc).items.map((item) => item.id), [
    'a00000',
    's00000',
  ])
})

Deno.test('a colour out of schema reads as none, and free text has none', () => {
  const { doc, node } = board()
  node(null, { id: 'c00000', kind: 'sticky', ...frame, color: 'teal' })
  node(null, { id: 'c00001', kind: 'text', ...frame, color: 'pink' })
  node(null, { id: 'c00002', kind: 'rect', ...frame, color: 'pink' })
  doc.commit()
  assertEquals(boardOf(doc).items.map(({ id, color }) => [id, color]), [
    ['c00000', undefined],
    ['c00001', undefined],
    ['c00002', 'pink'],
  ])
})

Deno.test('a file card turned into a sticky stays, without its path', () => {
  for (const dropsPath of [false, true]) {
    const { doc, node, connectors } = board()
    const card = node(null, {
      id: 'f00000',
      kind: 'file',
      path: '/a.png',
      ...frame,
    })
    node(null, { id: 'b00000', kind: 'sticky', ...frame })
    const connector = connectors.setContainer('c00000', new LoroMap())
    connector.set('from', 'f00000')
    connector.set('to', 'b00000')
    connector.set('style', 'straight')
    doc.commit()
    const replica = new LoroDoc()
    replica.import(doc.export({ mode: 'snapshot' }))
    const before = replica.oplogVersion()
    card.data.set('kind', 'sticky')
    if (dropsPath) card.data.delete('path')
    doc.commit()
    replica.import(doc.export({ mode: 'update', from: before }))
    const read = boardOf(replica)
    assertEquals(read.items.map(({ id, kind, path }) => [id, kind, path]), [
      ['f00000', 'sticky', undefined],
      ['b00000', 'sticky', undefined],
    ])
    assertEquals(read.connectors.map((c) => c.id), ['c00000'])
  }
})

Deno.test('reads connectors; a field out of schema reads as its default', () => {
  const { doc, node, connectors } = board()
  node(null, { id: 'a00000', kind: 'sticky', ...frame })
  node(null, { id: 'b00000', kind: 'rect', ...frame })
  const add = (id: string, fields: Record<string, unknown>) => {
    const map = connectors.setContainer(id, new LoroMap())
    for (const [key, value] of Object.entries(fields)) map.set(key, value)
    return map
  }
  const ok = add('c5n7r8', {
    from: 'a00000',
    to: 'b00000',
    style: 'elbow',
    toSide: 'left',
    offset: 12.5,
  })
  ok.setContainer('label', new LoroText()).insert(0, 'depends on')
  add('c00001', { from: 'a00000', to: 'zzzzzz', style: 'elbow' })
  add('c00002', {
    from: 'a00000',
    to: 'b00000',
    fromSide: 'middle',
    style: 'curved',
    offset: '1',
    arrow: 'x',
    label: 'plain',
  })
  add('c00003', { from: 'a00000' })
  connectors.set('c00004', 'not a map')
  doc.commit()
  assertEquals(boardOf(doc).connectors, [{
    id: 'c00002',
    from: 'a00000',
    to: 'b00000',
    style: 'straight',
    offset: 0,
    arrow: 'end',
    label: [],
  }, {
    id: 'c5n7r8',
    from: 'a00000',
    to: 'b00000',
    toSide: 'left',
    style: 'elbow',
    offset: 12.5,
    arrow: 'end',
    label: [{ text: 'depends on' }],
  }])
})

Deno.test('the lab board has the asked-for size and survives a round trip', () => {
  const doc = demoDoc(2000)
  const read = boardOf(doc)
  assertEquals(read.items.length, 2000)
  const copy = new LoroDoc()
  copy.import(doc.export({ mode: 'snapshot' }))
  assertEquals(boardOf(copy), read)
  assertEquals(boardOf(demoDoc(500)).items.length, 500)
})
