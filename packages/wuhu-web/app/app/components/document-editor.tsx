import { DragHandle } from '@tiptap/extension-drag-handle-react'
import { EditorContent, useEditor, useEditorState } from '@tiptap/react'
import { BubbleMenu } from '@tiptap/react/menus'
import { type MouseEvent, type ReactNode, useEffect, useRef } from 'react'
import { useNavigate, useOutletContext } from 'react-router'
import 'katex/dist/katex.min.css'
import { markdownEditorOptions, setEditable } from './markdown-editor'
import { spaceLink } from '~/lib/links'
import type { SpaceContext } from '~/routes/space'

function MenuButton({
  on,
  label,
  run,
  children,
}: {
  on?: boolean
  label: string
  run: () => void
  children: ReactNode
}) {
  return (
    <button
      type='button'
      className='wuhu-editor-menu-button'
      data-on={on}
      aria-label={label}
      aria-pressed={on}
      onMouseDown={(event) => {
        event.preventDefault()
        run()
      }}
    >
      {children}
    </button>
  )
}

// One editor for both faces of a document. Reading is `editable: false` on the
// same tree, so the layout never shifts when the Edit button flips it.
export function DocumentEditor({
  content,
  editable,
  sourcePath,
  onChange,
}: {
  content: string
  editable: boolean
  sourcePath: string
  onChange: (markdown: string) => void
}) {
  const navigate = useNavigate()
  const { group } = useOutletContext<SpaceContext>()
  const loaded = useRef(content)
  const editor = useEditor({
    ...markdownEditorOptions(content, editable, (markdown) => {
      loaded.current = markdown
      onChange(markdown)
    }),
    editorProps: {
      attributes: { class: 'wuhu-markdown wuhu-editor', spellcheck: 'false' },
    },
  })

  useEffect(() => {
    if (editor != null) setEditable(editor, editable)
  }, [editor, editable])

  // A remote revision replaces the tree only while nobody is typing into it;
  // an in-progress draft always wins over the wire.
  useEffect(() => {
    if (editor == null || content === loaded.current) return
    if (editable && editor.isFocused) return
    loaded.current = content
    editor.commands.setContent(content, {
      contentType: 'markdown',
      emitUpdate: false,
    })
  }, [editor, content, editable])

  const active = useEditorState({
    editor,
    selector: ({ editor: e }) =>
      e == null ? null : {
        h1: e.isActive('heading', { level: 1 }),
        h2: e.isActive('heading', { level: 2 }),
        h3: e.isActive('heading', { level: 3 }),
        bold: e.isActive('bold'),
        italic: e.isActive('italic'),
        strike: e.isActive('strike'),
        code: e.isActive('code'),
        link: e.isActive('link'),
        quote: e.isActive('blockquote'),
        bullet: e.isActive('bulletList'),
        task: e.isActive('taskList'),
      },
  })

  const onClick = (event: MouseEvent<HTMLDivElement>) => {
    const anchor = (event.target as HTMLElement).closest('a')
    if (anchor == null || !(event.currentTarget.contains(anchor))) return
    const href = anchor.getAttribute('href')
    if (href == null) return
    const to = spaceLink(href, group, sourcePath)
    if (to != null) {
      event.preventDefault()
      void navigate(to)
      return
    }
    if (!editable) {
      event.preventDefault()
      globalThis.open(href, '_blank', 'noopener')
    }
  }

  if (editor == null || active == null) return null

  const setLink = () => {
    const previous = editor.getAttributes('link').href as string | undefined
    const href = globalThis.prompt('Link', previous ?? '')
    if (href == null) return
    const chain = editor.chain().focus().extendMarkRange('link')
    if (href === '') chain.unsetLink().run()
    else chain.setLink({ href }).run()
  }

  return (
    <div
      className='wuhu-editor-frame'
      data-editable={editable}
      onClick={onClick}
    >
      {editable && (
        <DragHandle editor={editor} nested>
          <div className='wuhu-editor-handle' aria-hidden='true'>⋮⋮</div>
        </DragHandle>
      )}
      <BubbleMenu
        editor={editor}
        pluginKey='wuhuText'
        shouldShow={({ editor, from, to }) =>
          editor.isEditable && from !== to && !editor.isActive('codeBlock') &&
          !editor.isActive('table')}
      >
        <div className='wuhu-editor-menu' role='toolbar' aria-label='Format'>
          <MenuButton
            on={active.h1}
            label='Heading 1'
            run={() => editor.chain().focus().toggleHeading({ level: 1 }).run()}
          >
            H1
          </MenuButton>
          <MenuButton
            on={active.h2}
            label='Heading 2'
            run={() => editor.chain().focus().toggleHeading({ level: 2 }).run()}
          >
            H2
          </MenuButton>
          <MenuButton
            on={active.h3}
            label='Heading 3'
            run={() => editor.chain().focus().toggleHeading({ level: 3 }).run()}
          >
            H3
          </MenuButton>
          <span className='wuhu-editor-menu-gap' />
          <MenuButton
            on={active.bold}
            label='Bold'
            run={() => editor.chain().focus().toggleBold().run()}
          >
            <b>B</b>
          </MenuButton>
          <MenuButton
            on={active.italic}
            label='Italic'
            run={() => editor.chain().focus().toggleItalic().run()}
          >
            <i>I</i>
          </MenuButton>
          <MenuButton
            on={active.strike}
            label='Strikethrough'
            run={() => editor.chain().focus().toggleStrike().run()}
          >
            <s>S</s>
          </MenuButton>
          <MenuButton
            on={active.code}
            label='Code'
            run={() => editor.chain().focus().toggleCode().run()}
          >
            {'<>'}
          </MenuButton>
          <MenuButton on={active.link} label='Link' run={setLink}>
            ⌘K
          </MenuButton>
          <span className='wuhu-editor-menu-gap' />
          <MenuButton
            on={active.quote}
            label='Quote'
            run={() => editor.chain().focus().toggleBlockquote().run()}
          >
            ❝
          </MenuButton>
          <MenuButton
            on={active.bullet}
            label='Bullet list'
            run={() => editor.chain().focus().toggleBulletList().run()}
          >
            •
          </MenuButton>
          <MenuButton
            on={active.task}
            label='Task list'
            run={() => editor.chain().focus().toggleTaskList().run()}
          >
            ☐
          </MenuButton>
        </div>
      </BubbleMenu>
      <BubbleMenu
        editor={editor}
        pluginKey='wuhuTable'
        shouldShow={({ editor }) =>
          editor.isEditable && editor.isActive('table')}
        options={{ placement: 'top' }}
      >
        <div className='wuhu-editor-menu' role='toolbar' aria-label='Table'>
          <MenuButton
            label='Add row above'
            run={() => editor.chain().focus().addRowBefore().run()}
          >
            ↑ row
          </MenuButton>
          <MenuButton
            label='Add row below'
            run={() => editor.chain().focus().addRowAfter().run()}
          >
            ↓ row
          </MenuButton>
          <MenuButton
            label='Delete row'
            run={() => editor.chain().focus().deleteRow().run()}
          >
            ✕ row
          </MenuButton>
          <span className='wuhu-editor-menu-gap' />
          <MenuButton
            label='Add column before'
            run={() => editor.chain().focus().addColumnBefore().run()}
          >
            ← col
          </MenuButton>
          <MenuButton
            label='Add column after'
            run={() => editor.chain().focus().addColumnAfter().run()}
          >
            → col
          </MenuButton>
          <MenuButton
            label='Delete column'
            run={() => editor.chain().focus().deleteColumn().run()}
          >
            ✕ col
          </MenuButton>
          <span className='wuhu-editor-menu-gap' />
          <MenuButton
            label='Toggle header row'
            run={() => editor.chain().focus().toggleHeaderRow().run()}
          >
            header
          </MenuButton>
          <MenuButton
            label='Delete table'
            run={() => editor.chain().focus().deleteTable().run()}
          >
            ✕ table
          </MenuButton>
        </div>
      </BubbleMenu>
      <EditorContent editor={editor} />
    </div>
  )
}
