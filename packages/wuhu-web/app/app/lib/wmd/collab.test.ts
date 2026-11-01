import { GlobalRegistrator } from '@happy-dom/global-registrator'
import { Editor } from '@tiptap/core'
import type { Node as PMNode } from '@tiptap/pm/model'
import { TextSelection } from '@tiptap/pm/state'
import { EphemeralStore, LoroDoc } from 'loro-crdt/web'
import { docOf, writeDocument } from './binding.ts'
import {
  type Collab,
  collabExtension,
  importInto,
  type Presence,
  refreshPresence,
} from './collab.ts'
import { configuredDoc, loadLoro } from './loro.ts'
import {
  listNode,
  viewNode,
  wmdExtensions,
  wmdSchema as schema,
} from './schema.ts'

await loadLoro()

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

interface Peer {
  doc: LoroDoc
  presence: EphemeralStore<Record<string, Presence>>
  collab: Collab
  editor: Editor
}

function peer(name: string): Peer {
  const doc = configuredDoc(new LoroDoc())
  const presence = new EphemeralStore<Record<string, Presence>>(30_000)
  const collab: Collab = {
    doc,
    presence,
    self: doc.peerIdStr,
    identity: () => ({ name, color: '#123456' }),
  }
  const element = document.createElement('div')
  document.body.append(element)
  const editor = new Editor({
    element,
    extensions: [
      ...wmdExtensions({ src: () => null }),
      collabExtension(collab),
    ],
  })
  return { doc, presence, collab, editor }
}

// Each test gets a fresh DOM and ends every editor and store it opened.
async function withPeers(
  names: string[],
  body: (...peers: Peer[]) => void | Promise<void>,
) {
  GlobalRegistrator.register()
  const peers = names.map(peer)
  try {
    await body(...peers)
  } finally {
    for (const { editor, presence, doc } of peers) {
      editor.destroy()
      presence.destroy()
      doc.free()
    }
    await GlobalRegistrator.unregister()
  }
}

function sync(from: Peer, to: Peer) {
  importInto(to.editor.view, to.doc, () => {
    to.doc.import(
      from.doc.export({ mode: 'update', from: to.doc.oplogVersion() }),
    )
  })
}

// A document another writer (an agent, the server) made, as Loro bytes.
function seed(...blocks: PMNode[]): Uint8Array {
  const doc = configuredDoc(new LoroDoc())
  writeDocument(
    doc,
    docOf(schema, doc),
    schema.topNodeType.create(null, blocks),
  )
  doc.commit()
  const bytes = doc.export({ mode: 'update' })
  doc.free()
  return bytes
}

function load(target: Peer, bytes: Uint8Array) {
  importInto(target.editor.view, target.doc, () => target.doc.import(bytes))
}

const p = (text: string) =>
  schema.nodes.paragraph.create(null, text ? [schema.text(text)] : [])

function texts(target: Peer): string[] {
  const out: string[] = []
  target.editor.state.doc.forEach((block) => out.push(block.textContent))
  return out
}

// The editor and its Loro document say the same thing.
function assertBound(target: Peer) {
  assertEquals(
    docOf(schema, target.doc).toJSON(),
    target.editor.state.doc.toJSON(),
  )
}

// Position `offset` characters into top-level block `index`.
function at(target: Peer, index: number, offset: number): number {
  let pos = 1
  for (let i = 0; i < index; i++) {
    pos += target.editor.state.doc.child(i).nodeSize
  }
  return pos + offset
}

function caret(target: Peer, pos: number) {
  const { state, view } = target.editor
  view.dispatch(state.tr.setSelection(TextSelection.create(state.doc, pos)))
}

function type(target: Peer, text: string) {
  const { view } = target.editor
  const { from, to } = view.state.selection
  const handled = view.someProp(
    'handleTextInput',
    (handle) =>
      handle(
        view,
        from,
        to,
        text,
        () => view.state.tr.insertText(text, from, to),
      ),
  )
  if (!handled) view.dispatch(view.state.tr.insertText(text, from, to))
}

// ProseMirror's keymap decided what Mod means when it loaded, before the DOM.
const mac = /Mac|iP(hone|[oa]d)/.test(globalThis.navigator?.platform ?? '')
const mod = () => mac ? { metaKey: true } : { ctrlKey: true }

function press(target: Peer, key: string, modifiers: KeyboardEventInit = {}) {
  const { view } = target.editor
  const event = new KeyboardEvent('keydown', { key, ...modifiers })
  if (!view.someProp('handleKeyDown', (handle) => handle(view, event))) {
    throw new Error(`${key} was not handled`)
  }
}

function list(target: Peer, index: number) {
  const node = target.editor.state.doc.child(index)
  return node.type.name === listNode
    ? { level: node.attrs.level, style: node.attrs.style }
    : node.type.name
}

Deno.test('typing reaches the other editor through Loro', () =>
  withPeers(['Ada', 'Ben'], (ada, ben) => {
    load(ada, seed(p('world')))
    sync(ada, ben)
    caret(ada, at(ada, 0, 0))
    type(ada, 'hello ')
    sync(ada, ben)
    assertEquals(texts(ben), ['hello world'])
    assertBound(ada)
    assertBound(ben)
  }))

Deno.test('an import keeps the local caret on the text it was on', () =>
  withPeers(['Ada', 'Ben'], (ada, ben) => {
    load(ada, seed(p('world')))
    sync(ada, ben)
    caret(ben, at(ben, 0, 3))
    caret(ada, at(ada, 0, 0))
    type(ada, 'hello ')
    sync(ada, ben)
    assertEquals(ben.editor.state.selection.head, at(ben, 0, 9))
  }))

Deno.test('the first sync puts the caret at the start, not on a view block', () =>
  withPeers(['Ada'], (ada) => {
    load(
      ada,
      seed(
        p('intro'),
        schema.nodes[viewNode].create({ view: 'list', sql: 'SELECT 1' }),
      ),
    )
    assertEquals(ada.editor.state.selection.from, at(ada, 0, 0))
    assertEquals(ada.editor.state.selection.empty, true)
  }))

Deno.test('an imported link-like text is shown as written and never written back', () =>
  withPeers(['Ada'], (ada) => {
    const bytes = seed(p('Source: https://example.com'), p('two'), p('three'))
    load(ada, bytes)
    const theirs = new LoroDoc()
    theirs.import(bytes)
    assertEquals(ada.doc.oplogVersion().compare(theirs.oplogVersion()), 0)
    assertEquals(JSON.stringify(ada.editor.getJSON()).includes('"link"'), false)
    theirs.free()
  }))

Deno.test('undo reverts only my typing, after a peer typed in the same block', () =>
  withPeers(['Ada', 'Ben'], (ada, ben) => {
    load(ada, seed(p('')))
    sync(ada, ben)
    caret(ada, at(ada, 0, 0))
    type(ada, 'hello')
    sync(ada, ben)
    caret(ben, at(ben, 0, 5))
    type(ben, '!')
    sync(ben, ada)
    press(ada, 'z', mod())
    assertEquals(texts(ada), ['!'])
    assertBound(ada)
    sync(ada, ben)
    assertEquals(texts(ben), ['!'])
    press(ada, 'z', { ...mod(), shiftKey: true })
    assertEquals(texts(ada), ['hello!'])
    assertBound(ada)
  }))

Deno.test('a peer shows as a named caret once it has focused its editor', () =>
  withPeers(['Ada', 'Ben'], async (ada, ben) => {
    load(ada, seed(p('world')))
    sync(ada, ben)
    caret(ada, at(ada, 0, 2))
    refreshPresence(ada.editor.view, ada.collab)
    assertEquals(ada.presence.get(ada.collab.self)?.head, undefined)
    ada.editor.view.dom.dispatchEvent(new FocusEvent('focusin'))
    ben.presence.apply(ada.presence.encodeAll())
    await Promise.resolve()
    const label = ben.editor.view.dom.querySelector('.wmd-peer-name')
    assertEquals(label?.textContent, 'Ada')
  }))

Deno.test('list keys: markers, Enter, Tab, Backspace and the to-do toggle', () =>
  withPeers(['Ada'], (ada) => {
    load(ada, seed(p('')))
    caret(ada, at(ada, 0, 0))
    type(ada, '[')
    type(ada, ']')
    type(ada, ' ')
    assertEquals(list(ada, 0), { level: 0, style: 'todo' })
    type(ada, 'milk')
    press(ada, 'Enter', mod())
    assertEquals(list(ada, 0), { level: 0, style: 'done' })
    press(ada, 'Enter')
    assertEquals(list(ada, 1), { level: 0, style: 'todo' })
    press(ada, 'Tab')
    assertEquals(list(ada, 1), { level: 1, style: 'todo' })
    press(ada, 'Enter')
    assertEquals(list(ada, 1), { level: 0, style: 'todo' })
    press(ada, 'Backspace')
    assertEquals(list(ada, 1), 'paragraph')
    assertEquals(texts(ada), ['milk', ''])
    assertBound(ada)
  }))
