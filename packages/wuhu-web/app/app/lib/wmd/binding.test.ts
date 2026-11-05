import { LoroDoc, type LoroMap, type LoroText } from 'loro-crdt/web'
import type { Node as PMNode } from '@tiptap/pm/model'
import { docOf, writeDocument } from './binding.ts'
import { configuredDoc, loadLoro } from './loro.ts'
import { listNode, wmdSchema as schema } from './schema.ts'

await loadLoro()

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

const p = (text: string, blockId: string | null = null) =>
  schema.nodes.paragraph.create({ blockId }, text ? [schema.text(text)] : [])
const item = (text: string, level: number, style: string) =>
  schema.nodes[listNode].create(
    { level, style },
    text ? [schema.text(text)] : [],
  )
const page = (...blocks: PMNode[]) => schema.topNodeType.create(null, blocks)

// What a peer sees: the Loro state as blocks, without ids.
function shape(doc: LoroDoc): unknown {
  return docOf(schema, doc).toJSON().content.map((
    block: { type: string; attrs: Record<string, unknown>; content?: unknown },
  ) => {
    const { blockId: _, ...attrs } = block.attrs
    return { type: block.type, attrs, content: block.content ?? [] }
  })
}

function peer(): LoroDoc {
  return configuredDoc(new LoroDoc())
}

function sync(from: LoroDoc, to: LoroDoc) {
  to.import(from.export({ mode: 'update', from: to.oplogVersion() }))
}

// Writes `next` into `doc` the way the editor does and returns the editor's
// document with the ids it was given.
function edit(doc: LoroDoc, before: PMNode, next: PMNode): PMNode {
  writeDocument(doc, before, next)
  doc.commit()
  return docOf(schema, doc)
}

Deno.test('a peer reads exactly the blocks and marks the editor wrote', () => {
  const a = peer()
  const b = peer()
  const bold = schema.marks.bold.create()
  const link = schema.marks.link.create({ href: 'https://example.com' })
  const written = page(
    schema.nodes.heading.create({ level: 2 }, [schema.text('Title')]),
    schema.nodes.paragraph.create(null, [
      schema.text('plain '),
      schema.text('bold', [bold]),
      schema.nodes.hardBreak.create(),
      schema.text('site', [link]),
    ]),
    item('first', 0, 'todo'),
    item('nested', 1, 'ordered'),
    schema.nodes.codeBlock.create(null, [schema.text('a\n  b')]),
  )
  edit(a, docOf(schema, a), written)
  sync(a, b)
  assertEquals(shape(b), shape(a))
  const blocks = a.getMovableList('blocks').toJSON() as Record<
    string,
    unknown
  >[]
  assertEquals(blocks.map((block) => block.kind), [
    'h2',
    'paragraph',
    'list',
    'list',
    'code',
  ])
  assertEquals(blocks[1].text, 'plain bold\nsite')
  assertEquals(blocks[3].level, 1)
  assertEquals(blocks[3].style, 'ordered')
})

Deno.test('concurrent typing in one block converges for both peers', () => {
  const a = peer()
  const b = peer()
  let pmA = edit(a, docOf(schema, a), page(p('hello world')))
  sync(a, b)
  let pmB = docOf(schema, b)
  const id = pmA.child(0).attrs.blockId as string
  pmA = edit(a, pmA, page(p('hello brave world', id)))
  pmB = edit(b, pmB, page(p('hello world!', id)))
  sync(a, b)
  sync(b, a)
  assertEquals(a.getMovableList('blocks').toJSON(), [
    { kind: 'paragraph', text: 'hello brave world!' },
  ])
  assertEquals(shape(a), shape(b))
})

Deno.test('a block that changes kind keeps its identity', () => {
  const a = peer()
  const pm = edit(a, docOf(schema, a), page(p('one'), p('two')))
  const second = pm.child(1).attrs.blockId as string
  const changed = edit(
    a,
    pm,
    page(
      pm.child(0),
      schema.nodes.heading.create({ level: 1 }, [
        schema.text('two'),
      ]),
    ),
  )
  assertEquals(changed.child(1).attrs.blockId, second)
  assertEquals(changed.child(1).type.name, 'heading')
})

Deno.test('a split adds a block and a join removes one', () => {
  const a = peer()
  const b = peer()
  const pm = edit(a, docOf(schema, a), page(p('ab')))
  const id = pm.child(0).attrs.blockId as string
  const split = edit(a, pm, page(p('a', id), p('b', id)))
  assertEquals(split.childCount, 2)
  assertEquals(split.child(0).attrs.blockId, id)
  sync(a, b)
  assertEquals(shape(b), shape(a))
  edit(a, split, page(p('ab', id)))
  sync(a, b)
  assertEquals(b.getMovableList('blocks').toJSON(), [
    { kind: 'paragraph', text: 'ab' },
  ])
})

Deno.test('inline code is the code mark, both ways', () => {
  const a = peer()
  const b = peer()
  const code = schema.marks.code.create()
  edit(
    a,
    docOf(schema, a),
    page(schema.nodes.paragraph.create(null, [
      schema.text('a '),
      schema.text('b', [code]),
      schema.text(' c'),
    ])),
  )
  sync(a, b)
  const text = b.getMovableList('blocks').get(0) as LoroMap
  assertEquals((text.get('text') as LoroText).toDelta(), [
    { insert: 'a ' },
    { insert: 'b', attributes: { code: true } },
    { insert: ' c' },
  ])
  assertEquals(shape(b), shape(a))
  assertEquals(
    docOf(schema, b).child(0).child(1).marks.map((mark) => mark.type.name),
    ['code'],
  )
})
