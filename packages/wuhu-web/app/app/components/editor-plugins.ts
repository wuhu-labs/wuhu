import { Extension } from '@tiptap/core'
import type { Node as PMNode } from '@tiptap/pm/model'
import {
  NodeSelection,
  Plugin,
  PluginKey,
  TextSelection,
} from '@tiptap/pm/state'
import { Decoration, DecorationSet } from '@tiptap/pm/view'
import { callout, mentions } from '~/lib/editor-marks'

function decorate(doc: PMNode): DecorationSet {
  const decorations: Decoration[] = []
  doc.descendants((node, pos) => {
    if (node.type.name === 'blockquote') {
      const first = node.firstChild
      const lead = first?.firstChild
      if (first?.type.name === 'paragraph' && lead?.isText && lead.text) {
        const found = callout(lead.text)
        if (found != null) {
          decorations.push(
            Decoration.node(pos, pos + node.nodeSize, {
              class: 'wuhu-callout',
              'data-kind': found.kind,
              'data-title': found.title,
            }),
          )
          const textStart = pos + 2
          decorations.push(
            Decoration.inline(textStart, textStart + found.markerLength, {
              class: 'wuhu-callout-marker',
            }),
          )
        }
      }
      return true
    }
    if (
      node.isText && node.text &&
      !node.marks.some((m) => m.type.name === 'link' || m.type.name === 'code')
    ) {
      for (const range of mentions(node.text)) {
        decorations.push(
          Decoration.inline(pos + range.from, pos + range.to, {
            class: 'wuhu-mention',
          }),
        )
      }
    }
    return !node.isTextblock || node.type.name === 'paragraph'
  })
  return DecorationSet.create(doc, decorations)
}

// Callouts and @mentions are presentation over plain markdown, exactly as the
// remark pass treats them for read-only views; the source text never changes.
export const ContentMarks = Extension.create({
  name: 'wuhuContentMarks',
  addProseMirrorPlugins() {
    return [
      new Plugin({
        key: new PluginKey('wuhuContentMarks'),
        state: {
          init: (_, state) => decorate(state.doc),
          apply: (tr, old) => (tr.docChanged ? decorate(tr.doc) : old),
        },
        props: {
          decorations(state) {
            return this.getState(state)
          },
        },
      }),
    ]
  },
})

// A drop leaves the moved block node-selected, which paints a focus ring
// around a paragraph that is not an atom. Land the caret inside it instead;
// atoms (images, math) keep their node selection.
export const SettleAfterDrop = Extension.create({
  name: 'wuhuSettleAfterDrop',
  addProseMirrorPlugins() {
    return [
      new Plugin({
        key: new PluginKey('wuhuSettleAfterDrop'),
        appendTransaction(transactions, _old, state) {
          const dropped = transactions.some((tr) =>
            tr.getMeta('uiEvent') === 'drop'
          )
          const selection = state.selection
          if (!dropped || !(selection instanceof NodeSelection)) return null
          if (selection.node.isAtom) return null
          const inside = TextSelection.near(
            state.doc.resolve(selection.from + 1),
          )
          return state.tr.setSelection(inside)
        },
      }),
    ]
  },
})
