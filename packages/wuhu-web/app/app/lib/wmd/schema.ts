import { Extension, getSchema, InputRule, Node } from '@tiptap/core'
import type { Node as PMNode, NodeType } from '@tiptap/pm/model'
import { type EditorState, Plugin, PluginKey } from '@tiptap/pm/state'
import { Decoration, DecorationSet } from '@tiptap/pm/view'
import StarterKit from '@tiptap/starter-kit'

export type ListStyle = 'unordered' | 'ordered' | 'todo' | 'done'

// Every top-level node is one block of the Loro document; `blockId` names its
// container, null until the binding has created it.
const blockId = {
  default: null,
  rendered: false,
  keepOnSplit: false,
}

const BlockIds = Extension.create({
  name: 'wmdBlockIds',
  addGlobalAttributes: () => [
    { types: ['heading', 'paragraph', 'codeBlock'], attributes: { blockId } },
  ],
})

const Document = Node.create({
  name: 'doc',
  topNode: true,
  content: 'block+',
})

export const listNode = 'wmdList'
export const viewNode = 'wmdView'

function ordinalOf(decorations: readonly Decoration[]): number | undefined {
  for (const decoration of decorations) {
    const ordinal = (decoration.spec as { ordinal?: number }).ordinal
    if (ordinal != null) return ordinal
  }
}

const ListBlock = Node.create({
  name: listNode,
  group: 'block',
  content: 'inline*',
  defining: true,
  addAttributes: () => ({
    blockId,
    level: { default: 0, rendered: false },
    style: { default: 'unordered', rendered: false },
  }),
  parseHTML: () => [{
    tag: 'div[data-wmd-list]',
    getAttrs: (element) => ({
      style: element.getAttribute('data-wmd-list'),
      level: Number(element.getAttribute('data-level') ?? 0),
    }),
  }],
  renderHTML: ({ node }) => [
    'div',
    { 'data-wmd-list': node.attrs.style, 'data-level': node.attrs.level },
    0,
  ],
  addNodeView: () => ({ node: initial, getPos, editor, decorations }) => {
    let node = initial
    const dom = document.createElement('div')
    const marker = document.createElement('span')
    const content = document.createElement('div')
    marker.contentEditable = 'false'
    marker.className = 'wmd-marker'
    content.className = 'wmd-list-text'
    dom.append(marker, content)
    const draw = (ordinal: number | undefined) => {
      const style = node.attrs.style as ListStyle
      dom.className = 'wmd-list'
      dom.dataset.style = style
      dom.style.setProperty('--wmd-level', String(node.attrs.level))
      marker.textContent = style === 'ordered'
        ? `${ordinal ?? 1}.`
        : style === 'unordered'
        ? '•'
        : ''
    }
    marker.addEventListener('mousedown', (event) => {
      event.preventDefault()
      const style = node.attrs.style as ListStyle
      const pos = typeof getPos === 'function' ? getPos() : undefined
      if (!editor.isEditable || pos == null) return
      if (style !== 'todo' && style !== 'done') return
      editor.view.dispatch(
        editor.state.tr.setNodeAttribute(
          pos,
          'style',
          style === 'todo' ? 'done' : 'todo',
        ),
      )
    })
    draw(ordinalOf(decorations))
    return {
      dom,
      contentDOM: content,
      update: (next, nextDecorations) => {
        if (next.type !== node.type) return false
        node = next
        draw(ordinalOf(nextDecorations))
        return true
      },
    }
  },
})

export interface ViewFrame {
  src(view: { view: string; config: unknown; sql: string }): string | null
}

export const viewKinds = ['list', 'kanban', 'wall', 'map'] as const

const ViewBlock = Node.create<ViewFrame>({
  name: viewNode,
  group: 'block',
  atom: true,
  selectable: true,
  addOptions: () => ({ src: () => null }),
  addAttributes: () => ({
    blockId,
    view: { default: 'list', rendered: false },
    config: { default: null, rendered: false },
    sql: { default: '', rendered: false },
  }),
  parseHTML: () => [{ tag: 'div[data-wmd-view]' }],
  renderHTML: () => ['div', { 'data-wmd-view': '' }],
  addNodeView() {
    const frameSrc = this.options.src
    return ({ node: initial, getPos, editor }) => {
      let node = initial
      const dom = document.createElement('div')
      dom.className = 'wmd-view'
      dom.contentEditable = 'false'
      const bar = document.createElement('div')
      bar.className = 'wmd-view-bar'
      const picker = document.createElement('select')
      for (const kind of viewKinds) {
        const option = document.createElement('option')
        option.value = option.textContent = kind
        picker.append(option)
      }
      picker.addEventListener('change', () => {
        const pos = typeof getPos === 'function' ? getPos() : undefined
        if (!editor.isEditable || pos == null) {
          picker.value = node.attrs.view as string
          return
        }
        editor.view.dispatch(
          editor.state.tr.setNodeAttribute(pos, 'view', picker.value),
        )
      })
      const sql = document.createElement('code')
      bar.append(picker, sql)
      const frame = document.createElement('iframe')
      frame.className = 'wmd-view-frame'
      frame.sandbox.add('allow-scripts', 'allow-same-origin')
      dom.append(bar, frame)
      const draw = () => {
        const attrs = node.attrs as {
          view: string
          config: unknown
          sql: string
        }
        picker.value = attrs.view
        sql.textContent = attrs.sql
        const src = frameSrc(attrs)
        if (src != null && frame.getAttribute('src') !== src) frame.src = src
      }
      draw()
      return {
        dom,
        update: (next) => {
          if (next.type !== node.type) return false
          node = next
          draw()
          return true
        },
        stopEvent: (event) => event.target === picker,
        ignoreMutation: () => true,
      }
    }
  },
})

// Ordered items count up through consecutive list items at their level; any
// other block, or a shallower item that is not ordered, starts the count anew.
function ordinals(doc: PMNode): DecorationSet {
  const decorations: Decoration[] = []
  const counts: number[] = []
  doc.forEach((node, pos) => {
    if (node.type.name !== listNode) {
      counts.length = 0
      return
    }
    const level = node.attrs.level as number
    counts.length = Math.min(counts.length, level + 1)
    while (counts.length <= level) counts.push(0)
    if (node.attrs.style !== 'ordered') {
      counts[level] = 0
      return
    }
    counts[level] += 1
    decorations.push(
      Decoration.node(pos, pos + node.nodeSize, {}, { ordinal: counts[level] }),
    )
  })
  return DecorationSet.create(doc, decorations)
}

const ordinalKey = new PluginKey<DecorationSet>('wmdOrdinals')

const Ordinals = Extension.create({
  name: 'wmdOrdinals',
  addProseMirrorPlugins: () => [
    new Plugin<DecorationSet>({
      key: ordinalKey,
      state: {
        init: (_, state) => ordinals(state.doc),
        apply: (tr, old) => (tr.docChanged ? ordinals(tr.doc) : old),
      },
      props: {
        decorations: (state) => ordinalKey.getState(state),
      },
    }),
  ],
})

function listItemAt(state: EditorState) {
  const { $from, empty } = state.selection
  if ($from.depth !== 1 || $from.parent.type.name !== listNode) return null
  return { node: $from.parent, pos: $from.before(1), $from, empty }
}

const maxLevel = 8

function listStyleRule(
  find: RegExp,
  style: (match: RegExpMatchArray) => ListStyle,
  list: () => NodeType,
) {
  return new InputRule({
    find,
    handler: ({ state, range, match }) => {
      const $start = state.doc.resolve(range.from)
      if ($start.depth !== 1) return null
      const parent = $start.parent
      const kind = parent.type.name
      if (kind !== 'paragraph' && kind !== listNode) return null
      state.tr.delete(range.from, range.to).setBlockType(
        range.from,
        range.from,
        list(),
        {
          blockId: parent.attrs.blockId,
          level: kind === listNode ? parent.attrs.level : 0,
          style: style(match),
        },
      )
    },
  })
}

const Keys = Extension.create({
  name: 'wmdKeys',
  priority: 1000,
  addInputRules() {
    const list = () => this.editor.schema.nodes[listNode]
    return [
      listStyleRule(
        /^\[([ xX]?)\]\s$/,
        (m) => m[1].trim() ? 'done' : 'todo',
        list,
      ),
      listStyleRule(/^[-+*]\s$/, () => 'unordered', list),
      listStyleRule(/^\d+\.\s$/, () => 'ordered', list),
    ]
  },
  addKeyboardShortcuts() {
    const setLevel = (delta: number) => {
      const item = listItemAt(this.editor.state)
      if (item == null) return false
      const level = item.node.attrs.level as number
      const next = Math.max(0, Math.min(maxLevel, level + delta))
      if (next !== level) {
        this.editor.view.dispatch(
          this.editor.state.tr.setNodeAttribute(item.pos, 'level', next),
        )
      }
      return true
    }
    return {
      Enter: () => {
        const state = this.editor.state
        const item = listItemAt(state)
        if (item == null) return false
        const { node, pos, $from } = item
        if (node.content.size === 0) {
          if ((node.attrs.level as number) > 0) return setLevel(-1)
          this.editor.view.dispatch(
            state.tr.setNodeMarkup(pos, state.schema.nodes.paragraph, {
              blockId: node.attrs.blockId,
            }),
          )
          return true
        }
        const style = node.attrs.style === 'done' ? 'todo' : node.attrs.style
        const tr = state.tr.deleteSelection()
        tr.split(tr.mapping.map($from.pos), 1, [{
          type: node.type,
          attrs: { blockId: null, level: node.attrs.level, style },
        }])
        this.editor.view.dispatch(tr.scrollIntoView())
        return true
      },
      Tab: () => setLevel(1) || this.editor.isActive('codeBlock'),
      'Shift-Tab': () => setLevel(-1) || this.editor.isActive('codeBlock'),
      Backspace: () => {
        const item = listItemAt(this.editor.state)
        if (item == null || !item.empty || item.$from.parentOffset !== 0) {
          return false
        }
        if ((item.node.attrs.level as number) > 0) return setLevel(-1)
        this.editor.view.dispatch(
          this.editor.state.tr.setNodeMarkup(
            item.pos,
            this.editor.schema.nodes.paragraph,
            { blockId: item.node.attrs.blockId },
          ),
        )
        return true
      },
      'Mod-k': () => {
        const previous = this.editor.getAttributes('link').href as
          | string
          | undefined
        const href = globalThis.prompt('Link', previous ?? '')
        if (href == null) return true
        const chain = this.editor.chain().focus().extendMarkRange('link')
        if (href === '') chain.unsetLink().run()
        else chain.setLink({ href }).run()
        return true
      },
      'Mod-Enter': () => {
        const item = listItemAt(this.editor.state)
        if (item == null) return false
        const style = item.node.attrs.style as ListStyle
        this.editor.view.dispatch(
          this.editor.state.tr.setNodeAttribute(
            item.pos,
            'style',
            style === 'todo' ? 'done' : 'todo',
          ),
        )
        return true
      },
    }
  },
})

export function wmdExtensions(frame: ViewFrame) {
  return [
    StarterKit.configure({
      document: false,
      heading: { levels: [1, 2, 3] },
      blockquote: false,
      bulletList: false,
      orderedList: false,
      listItem: false,
      listKeymap: false,
      strike: false,
      underline: false,
      horizontalRule: false,
      trailingNode: false,
      undoRedo: false,
      link: {
        openOnClick: false,
        protocols: [{ scheme: 'wuhu', optionalSlashes: true }],
      },
    }),
    Document,
    BlockIds,
    ListBlock,
    ViewBlock.configure(frame),
    Ordinals,
    Keys,
  ]
}

export const wmdSchema = getSchema(wmdExtensions({ src: () => null }))
