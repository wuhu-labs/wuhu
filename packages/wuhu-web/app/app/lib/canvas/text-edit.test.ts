import { LoroDoc, UndoManager } from 'loro-crdt/web'
import { loadLoro } from '~/lib/wmd/loro.ts'
import { wmdSchema as schema } from '~/lib/wmd/schema.ts'
import { boardOf, configuredBoard, type TextRun } from './board.ts'
import { CanvasEditor } from './editor.ts'
import { sceneOf } from './scene.ts'
import { finishText, inlineNodes, mergedText, runsOf } from './text-edit.ts'

await loadLoro()

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

Deno.test('runs survive the editor paragraph, newlines and marks (code too) included', () => {
  const runs: TextRun[] = [
    { text: 'Ship ' },
    { text: 'it', bold: true },
    { text: '\nnow', italic: true },
    { text: ' here', link: 'https://example.com' },
    { text: 'make', code: true },
  ]
  const paragraph = schema.nodes.paragraph.create(
    null,
    inlineNodes(schema, runs),
  )
  assertEquals(runsOf(paragraph), [
    { text: 'Ship ' },
    { text: 'it', bold: true },
    { text: '\n' },
    { text: 'now', italic: true },
    { text: ' here', link: 'https://example.com' },
    { text: 'make', code: true },
  ])
})

Deno.test('typing merges with a concurrent edit made since the base', () => {
  const doc = configuredBoard(new LoroDoc())
  const id = new CanvasEditor(doc).insert(
    'sticky',
    { x: 0, y: 0, w: 160, h: 160 },
    'yellow',
    { text: [{ text: 'Hello' }] },
  )
  doc.commit()
  const base = doc.frontiers()
  const remote = configuredBoard(new LoroDoc())
  remote.import(doc.export({ mode: 'snapshot' }))
  new CanvasEditor(remote).setText(id, [{ text: 'Hello world' }])
  remote.commit()
  doc.import(remote.export({ mode: 'update', from: doc.oplogVersion() }))
  assertEquals(mergedText(doc, { id }, base, [{ text: 'Hi Hello' }]), [
    { text: 'Hi Hello world' },
  ])
  new CanvasEditor(doc).delete([id])
  doc.commit()
  assertEquals(mergedText(doc, { id }, base, [{ text: 'Hi Hello' }]), null)
  assertEquals(boardOf(doc).items, [])
})

function twoPeers() {
  const doc = configuredBoard(new LoroDoc())
  const id = new CanvasEditor(doc).insert(
    'sticky',
    { x: 0, y: 0, w: 160, h: 160 },
    'yellow',
    { text: [{ text: 'Hello' }] },
  )
  doc.commit()
  const remote = configuredBoard(new LoroDoc())
  remote.import(doc.export({ mode: 'snapshot' }))
  const sync = () => {
    doc.import(remote.export({ mode: 'update', from: doc.oplogVersion() }))
    remote.import(doc.export({ mode: 'update', from: remote.oplogVersion() }))
  }
  return { doc, remote, id, sync }
}

const textOf = (doc: LoroDoc, id: string) =>
  boardOf(doc).items.find((item) => item.id === id)?.text

Deno.test('finishing merges with a remote edit imported since the last render', () => {
  const { doc, remote, id, sync } = twoPeers()
  const session = { id, base: doc.frontiers(), original: [{ text: 'Hello' }] }
  new CanvasEditor(remote).setText(id, [{ text: 'Hello world' }])
  remote.commit()
  sync()
  assertEquals(finishText(doc, session, [{ text: 'Hi Hello' }]), true)
  assertEquals(textOf(doc, id), [{ text: 'Hi Hello world' }])
  assertEquals(finishText(doc, session, [{ text: 'Hello' }]), false)
})

Deno.test('undo reverts only the local peer and keeps remote edits', () => {
  const { doc, remote, id, sync } = twoPeers()
  const undo = new UndoManager(doc, { mergeInterval: 0 })
  new CanvasEditor(doc).setFrame(id, { x: 40, y: 40, w: 160, h: 160 })
  doc.commit()
  const session = { id, base: doc.frontiers(), original: [{ text: 'Hello' }] }
  new CanvasEditor(remote).setText(id, [{ text: 'Hello world' }])
  new CanvasEditor(remote).setColor([id], 'pink')
  remote.commit()
  sync()
  finishText(doc, session, [{ text: 'Hi Hello' }])
  const item = () => boardOf(doc).items.find((i) => i.id === id)!
  assertEquals(item().text, [{ text: 'Hi Hello world' }])

  undo.undo()
  assertEquals(item().text, [{ text: 'Hello world' }])
  assertEquals([item().x, item().y, item().color], [40, 40, 'pink'])
  undo.undo()
  assertEquals([item().x, item().y, item().color], [0, 0, 'pink'])
  assertEquals(undo.canUndo(), false)

  undo.redo()
  undo.redo()
  assertEquals(item().text, [{ text: 'Hi Hello world' }])
  assertEquals([item().x, item().y, item().color], [40, 40, 'pink'])
})

Deno.test('a connector label edits through the connector, merges and clears to no label', () => {
  const doc = configuredBoard(new LoroDoc())
  const editor = new CanvasEditor(doc)
  const box = { x: 0, y: 0, w: 100, h: 100 }
  const a = editor.insert('rect', box, 'blue')
  const b = editor.insert('rect', { ...box, x: 300 }, 'blue')
  const id = editor.connect({ from: a, to: b })
  doc.commit()
  const undo = new UndoManager(doc, { mergeInterval: 0 })
  const labelOf = () => boardOf(doc).connectors.find((c) => c.id === id)?.label
  const session = { id, label: true, base: doc.frontiers(), original: [] }
  assertEquals(finishText(doc, session, [{ text: 'sync' }]), true)
  assertEquals(labelOf(), [{ text: 'sync' }])
  assertEquals(sceneOf(boardOf(doc)).connectors[0].label?.runs, [{
    text: 'sync',
  }])

  const remote = configuredBoard(new LoroDoc())
  remote.import(doc.export({ mode: 'snapshot' }))
  const again = {
    id,
    label: true,
    base: doc.frontiers(),
    original: [{ text: 'sync' }],
  }
  new CanvasEditor(remote).updateConnector(
    id,
    (c) => (c.label = [{ text: 'sync now' }]),
  )
  remote.commit()
  doc.import(remote.export({ mode: 'update', from: doc.oplogVersion() }))
  assertEquals(finishText(doc, again, [{ text: 'live sync' }]), true)
  assertEquals(labelOf(), [{ text: 'live sync now' }])

  const cleared = {
    id,
    label: true,
    base: doc.frontiers(),
    original: [{ text: 'live sync now' }],
  }
  assertEquals(finishText(doc, cleared, []), true)
  assertEquals(labelOf(), [])
  assertEquals(sceneOf(boardOf(doc)).connectors[0].label, undefined)
  undo.undo()
  assertEquals(labelOf(), [{ text: 'live sync now' }])
})
