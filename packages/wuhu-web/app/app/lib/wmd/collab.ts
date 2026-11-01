import { Extension } from '@tiptap/core'
import {
  type EditorState,
  Plugin,
  PluginKey,
  Selection,
  TextSelection,
  type Transaction,
} from '@tiptap/pm/state'
import { Decoration, DecorationSet, type EditorView } from '@tiptap/pm/view'
import {
  Cursor,
  type EphemeralStore,
  type LoroDoc,
  UndoManager,
} from 'loro-crdt/web'
import {
  blockNodes,
  blockStart,
  cursorAt,
  positionOf,
  writeDocument,
} from './binding.ts'

export type Presence = {
  name: string
  color: string
  anchor?: Uint8Array
  head?: Uint8Array
}

export type PresenceStore = EphemeralStore<Record<string, Presence>>

export interface Collab {
  doc: LoroDoc
  presence: PresenceStore
  // The key this client writes in the presence store: its peer id.
  self: string
  // Who this client is in presence, once the channel has said.
  identity(): { name: string; color: string } | null
}

const remoteKey = new PluginKey('wmdRemote')
const presenceKey = new PluginKey<DecorationSet>('wmdPresence')

// Makes the editor show the Loro document after `change` imported into it,
// keeping the local selection on the text it was on.
export function importInto(
  view: EditorView,
  doc: LoroDoc,
  change: () => void,
) {
  const before = view.state
  const { anchor, head } = before.selection
  const anchorCursor = cursorAt(doc, before.doc, anchor)
  const headCursor = anchor === head
    ? anchorCursor
    : cursorAt(doc, before.doc, head)
  change()
  const nodes = blockNodes(before.schema, doc)
  const old = before.doc
  let start = 0
  const shorter = Math.min(old.childCount, nodes.length)
  while (start < shorter && old.child(start).eq(nodes[start])) start++
  let oldEnd = old.childCount
  let newEnd = nodes.length
  while (
    oldEnd > start && newEnd > start &&
    old.child(oldEnd - 1).eq(nodes[newEnd - 1])
  ) {
    oldEnd--
    newEnd--
  }
  const tr = before.tr
  if (start !== oldEnd || start !== newEnd) {
    tr.replaceWith(
      blockStart(old, start),
      blockStart(old, oldEnd),
      nodes.slice(start, newEnd),
    )
    const nextAnchor = anchorCursor && positionOf(doc, tr.doc, anchorCursor)
    const nextHead = headCursor && positionOf(doc, tr.doc, headCursor)
    if (nextAnchor != null && nextHead != null) {
      tr.setSelection(TextSelection.create(tr.doc, nextAnchor, nextHead))
    } else if (
      anchorCursor == null && before.selection instanceof TextSelection
    ) {
      // A caret in text Loro has no block for yet (the empty editor before
      // the first sync) would map to the end, often onto a view block.
      tr.setSelection(Selection.atStart(tr.doc))
    }
  }
  tr.setMeta(remoteKey, true).setMeta('preventAutolink', true)
  view.dispatch(tr)
}

// What another plugin appends in reaction to an import is not this person's
// edit either: it stays in the editor and never reaches Loro.
function isRemote(tr: Transaction): boolean {
  const root = tr.getMeta('appendedTransaction') as Transaction | undefined
  return tr.getMeta(remoteKey) === true || root?.getMeta(remoteKey) === true
}

type Step = 'undo' | 'redo'

// Undo is Loro's: it reverts only this peer's ops, over whatever the others
// did since, and puts the caret back where it was before the step.
function history(view: EditorView, doc: LoroDoc) {
  let caret: Cursor | undefined
  const manager = new UndoManager(doc, {
    onPush: () => {
      const cursor = cursorAt(doc, view.state.doc, view.state.selection.head)
      return { value: null, cursors: cursor ? [cursor] : [] }
    },
    onPop: (_, { cursors }) => {
      caret = cursors[0]
    },
  })
  return {
    run(step: Step): boolean {
      if (!view.editable) return false
      caret = undefined
      importInto(view, doc, () => manager[step]())
      const pos = caret && positionOf(doc, view.state.doc, caret)
      if (pos != null) {
        view.dispatch(
          view.state.tr.setSelection(TextSelection.create(view.state.doc, pos)),
        )
      }
      return true
    },
    free: () => manager.free(),
  }
}

const historySteps: Record<string, Step> = {
  historyUndo: 'undo',
  historyRedo: 'redo',
}

function caret(presence: Presence): HTMLElement {
  const caret = document.createElement('span')
  caret.className = 'wmd-peer-caret'
  caret.style.setProperty('--wmd-peer', presence.color)
  const label = document.createElement('span')
  label.className = 'wmd-peer-name'
  label.textContent = presence.name
  caret.append('\u2060', label, '\u2060')
  return caret
}

function peerDecorations(collab: Collab, state: EditorState): DecorationSet {
  const decorations: Decoration[] = []
  const states = collab.presence.getAllStates()
  for (const [key, presence] of Object.entries(states)) {
    if (key === collab.self || presence?.head == null) continue
    const head = positionOf(
      collab.doc,
      state.doc,
      Cursor.decode(presence.head),
    )
    if (head == null) continue
    decorations.push(
      Decoration.widget(head, () => caret(presence), {
        key: `${key}:${presence.name}:${presence.color}`,
        side: 10,
      }),
    )
    const anchor = presence.anchor == null
      ? head
      : positionOf(collab.doc, state.doc, Cursor.decode(presence.anchor))
    if (anchor == null || anchor === head) continue
    decorations.push(
      Decoration.inline(Math.min(anchor, head), Math.max(anchor, head), {
        class: 'wmd-peer-selection',
        style: `--wmd-peer: ${presence.color}`,
      }),
    )
  }
  return DecorationSet.create(state.doc, decorations)
}

function sameBytes(a?: Uint8Array, b?: Uint8Array): boolean {
  if (a == null || b == null) return a === b
  return a.length === b.length && a.every((byte, i) => byte === b[i])
}

// A selection is published once the editor has had focus: an untouched
// editor's selection at the top is not where anyone is.
function publishSelection(
  collab: Collab,
  state: EditorState,
  engaged: boolean,
) {
  const identity = collab.identity()
  if (identity == null) return
  const { anchor, head } = state.selection
  const anchorCursor = engaged
    ? cursorAt(collab.doc, state.doc, anchor)?.encode()
    : undefined
  const headCursor = !engaged || anchor === head
    ? anchorCursor
    : cursorAt(collab.doc, state.doc, head)?.encode()
  const current = collab.presence.get(collab.self)
  if (
    current?.name === identity.name && current.color === identity.color &&
    sameBytes(current.anchor, anchorCursor) &&
    sameBytes(current.head, headCursor)
  ) return
  collab.presence.set(collab.self, {
    ...identity,
    ...(anchorCursor && headCursor
      ? { anchor: anchorCursor, head: headCursor }
      : {}),
  })
}

// Every local edit becomes Loro ops at once, so the Loro document always
// equals the editor's between transactions; remote changes enter only
// through `importInto`.
export function collabExtension(collab: Collab) {
  let steps: ReturnType<typeof history> | null = null
  const run = (step: Step) => () => steps?.run(step) ?? false
  return Extension.create({
    name: 'wmdCollab',
    addKeyboardShortcuts: () => ({
      'Mod-z': run('undo'),
      'Shift-Mod-z': run('redo'),
      'Mod-y': run('redo'),
    }),
    addProseMirrorPlugins: () => [
      new Plugin({
        key: remoteKey,
        appendTransaction(
          transactions: readonly Transaction[],
          before: EditorState,
          after: EditorState,
        ) {
          const local = transactions.some((tr) =>
            tr.docChanged && !isRemote(tr)
          )
          if (!local) return null
          const assigned = writeDocument(collab.doc, before.doc, after.doc)
          collab.doc.commit()
          if (assigned.size === 0) return null
          const tr = after.tr
          for (const [index, id] of assigned) {
            tr.setNodeAttribute(blockStart(after.doc, index), 'blockId', id)
          }
          return tr.setMeta(remoteKey, true)
        },
        props: {
          handleDOMEvents: {
            beforeinput: (_, event) => {
              const step = historySteps[event.inputType]
              if (step == null || steps == null) return false
              event.preventDefault()
              return steps.run(step)
            },
          },
        },
        view(view) {
          steps = history(view, collab.doc)
          return {
            destroy: () => {
              steps?.free()
              steps = null
            },
          }
        },
      }),
      new Plugin<DecorationSet>({
        key: presenceKey,
        state: {
          init: (_, state) => peerDecorations(collab, state),
          apply(tr, old, _before, state) {
            if (tr.getMeta(remoteKey) === true || tr.getMeta(presenceKey)) {
              return peerDecorations(collab, state)
            }
            return old.map(tr.mapping, tr.doc)
          },
        },
        props: {
          decorations: (state) => presenceKey.getState(state),
        },
        view(view) {
          const stop = collab.presence.subscribe((event) => {
            if (event.by === 'local') return
            queueMicrotask(() => {
              if (view.isDestroyed) return
              view.dispatch(view.state.tr.setMeta(presenceKey, true))
            })
          })
          let engaged = false
          const publish = () => publishSelection(collab, view.state, engaged)
          const focused = () => {
            engaged = true
            publish()
          }
          view.dom.addEventListener('focusin', focused)
          engagement.set(collab, publish)
          publish()
          return {
            update: (next, previous) => {
              if (next.hasFocus()) engaged = true
              if (
                previous.doc !== next.state.doc ||
                !previous.selection.eq(next.state.selection)
              ) publish()
            },
            destroy: () => {
              stop()
              view.dom.removeEventListener('focusin', focused)
              engagement.delete(collab)
              collab.presence.delete(collab.self)
            },
          }
        },
      }),
    ],
  })
}

const engagement = new WeakMap<Collab, () => void>()

// Publishes this client's entry once the channel knows who it is.
export function refreshPresence(view: EditorView, collab: Collab) {
  engagement.get(collab)?.()
  view.dispatch(view.state.tr.setMeta(presenceKey, true))
}
