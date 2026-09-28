import { computePosition, flip, offset, shift } from '@floating-ui/dom'
import { type Editor, Extension, type Range } from '@tiptap/core'
import { PluginKey } from '@tiptap/pm/state'
import Suggestion, {
  type SuggestionKeyDownProps,
  type SuggestionProps,
} from '@tiptap/suggestion'
import { forwardRef, useEffect, useImperativeHandle, useState } from 'react'
import { createRoot, type Root } from 'react-dom/client'

interface Item {
  title: string
  hint: string
  glyph: string
  keywords?: string
  run: (editor: Editor, range: Range) => void
}

const items: Item[] = [
  {
    title: 'Text',
    hint: 'Plain paragraph',
    glyph: 'T',
    run: (e, r) => e.chain().focus().deleteRange(r).setParagraph().run(),
  },
  {
    title: 'Heading 1',
    hint: 'Section',
    glyph: 'H1',
    run: (e, r) =>
      e.chain().focus().deleteRange(r).setHeading({ level: 1 }).run(),
  },
  {
    title: 'Heading 2',
    hint: 'Subsection',
    glyph: 'H2',
    run: (e, r) =>
      e.chain().focus().deleteRange(r).setHeading({ level: 2 }).run(),
  },
  {
    title: 'Heading 3',
    hint: 'Minor heading',
    glyph: 'H3',
    run: (e, r) =>
      e.chain().focus().deleteRange(r).setHeading({ level: 3 }).run(),
  },
  {
    title: 'Bullet list',
    hint: 'Unordered',
    glyph: '•',
    keywords: 'ul',
    run: (e, r) => e.chain().focus().deleteRange(r).toggleBulletList().run(),
  },
  {
    title: 'Numbered list',
    hint: 'Ordered',
    glyph: '1.',
    keywords: 'ol',
    run: (e, r) => e.chain().focus().deleteRange(r).toggleOrderedList().run(),
  },
  {
    title: 'To-do',
    hint: 'Task list',
    glyph: '☐',
    keywords: 'task check',
    run: (e, r) => e.chain().focus().deleteRange(r).toggleTaskList().run(),
  },
  {
    title: 'Quote',
    hint: 'Blockquote',
    glyph: '❝',
    run: (e, r) => e.chain().focus().deleteRange(r).setBlockquote().run(),
  },
  {
    title: 'Callout',
    hint: 'Note block',
    glyph: '!',
    keywords: 'note tip warning',
    run: (e, r) =>
      e.chain().focus().deleteRange(r).setBlockquote().insertContent('[!NOTE] ')
        .run(),
  },
  {
    title: 'Code block',
    hint: 'Fenced code',
    glyph: '</>',
    keywords: 'pre',
    run: (e, r) => e.chain().focus().deleteRange(r).setCodeBlock().run(),
  },
  {
    title: 'Table',
    hint: '3 × 3 with header',
    glyph: '⊞',
    run: (e, r) =>
      e.chain().focus().deleteRange(r).insertTable({
        rows: 3,
        cols: 3,
        withHeaderRow: true,
      }).run(),
  },
  {
    title: 'Math block',
    hint: 'Display LaTeX',
    glyph: '∑',
    keywords: 'latex katex',
    run: (e, r) =>
      e.chain().focus().deleteRange(r).insertBlockMath({ latex: 'E = mc^2' })
        .run(),
  },
  {
    title: 'Divider',
    hint: 'Horizontal rule',
    glyph: '—',
    keywords: 'hr',
    run: (e, r) => e.chain().focus().deleteRange(r).setHorizontalRule().run(),
  },
]

interface ListHandle {
  onKeyDown: (props: SuggestionKeyDownProps) => boolean
}

const List = forwardRef<ListHandle, SuggestionProps<Item>>(
  function List({ items, command }, ref) {
    const [selected, setSelected] = useState(0)
    useEffect(() => setSelected(0), [items])
    useImperativeHandle(
      ref,
      () => ({
        onKeyDown: ({ event }) => {
          if (event.key === 'ArrowUp') {
            setSelected((s) => (s + items.length - 1) % items.length)
            return true
          }
          if (event.key === 'ArrowDown') {
            setSelected((s) => (s + 1) % items.length)
            return true
          }
          if (event.key === 'Enter') {
            if (items[selected]) command(items[selected])
            return true
          }
          return false
        },
      }),
      [items, selected, command],
    )
    return (
      <div className='wuhu-slash' role='listbox'>
        {items.length === 0 && (
          <div className='wuhu-slash-empty'>No block matches</div>
        )}
        {items.map((item, index) => (
          <div
            key={item.title}
            role='option'
            aria-selected={index === selected}
            className='wuhu-slash-item'
            data-selected={index === selected}
            onMouseEnter={() => setSelected(index)}
            onMouseDown={(event) => {
              event.preventDefault()
              command(item)
            }}
          >
            <span className='wuhu-slash-glyph'>{item.glyph}</span>
            <span>
              {item.title}
              <small>{item.hint}</small>
            </span>
          </div>
        ))}
      </div>
    )
  },
)

function matches(query: string): Item[] {
  const needle = query.toLowerCase()
  return items.filter((item) =>
    `${item.title} ${item.keywords ?? ''}`.toLowerCase().includes(needle)
  )
}

export const SlashCommands = Extension.create({
  name: 'wuhuSlashCommands',
  addProseMirrorPlugins() {
    const editor = this.editor
    let host: HTMLDivElement | null = null
    let root: Root | null = null
    let handle: ListHandle | null = null

    const place = (clientRect: SuggestionProps['clientRect']) => {
      const rect = clientRect?.()
      if (host == null || rect == null) return
      const reference = { getBoundingClientRect: () => rect }
      void computePosition(reference, host, {
        placement: 'bottom-start',
        middleware: [offset(6), flip(), shift({ padding: 8 })],
      }).then(({ x, y }) => {
        if (host == null) return
        host.style.left = `${x}px`
        host.style.top = `${y}px`
      })
    }
    const render = (props: SuggestionProps<Item>) =>
      root?.render(
        <List
          {...props}
          ref={(next) => {
            handle = next
          }}
        />,
      )

    return [
      Suggestion<Item>({
        editor,
        pluginKey: new PluginKey('wuhuSlashCommands'),
        char: '/',
        items: ({ query }) => matches(query),
        command: ({ editor, range, props }) => props.run(editor, range),
        render: () => ({
          onStart: (props) => {
            host = document.createElement('div')
            host.className = 'wuhu-slash-host'
            document.body.appendChild(host)
            root = createRoot(host)
            render(props)
            place(props.clientRect)
          },
          onUpdate: (props) => {
            render(props)
            place(props.clientRect)
          },
          onKeyDown: (props) => {
            if (props.event.key === 'Escape') return true
            return handle?.onKeyDown(props) ?? false
          },
          onExit: () => {
            root?.unmount()
            host?.remove()
            host = null
            root = null
            handle = null
          },
        }),
      }),
    ]
  },
})
