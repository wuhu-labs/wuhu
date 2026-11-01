import { type Editor, getSchema, Node } from '@tiptap/core'
import StarterKit from '@tiptap/starter-kit'
import { EditorContent, useEditor } from '@tiptap/react'
import { useEffect } from 'react'
import type { ItemKind, TextRun } from '~/lib/canvas/board'
import { type SceneText, textColor } from '~/lib/canvas/scene'
import { inlineNodes, runsOf } from '~/lib/canvas/text-edit'
import { type CameraStore, useCamera, viewRect } from './canvas-chrome'

// An item's text, edited in place: one paragraph whose hard breaks are
// newlines, with `.wmd`'s bold, italic and link marks.

const OneParagraph = Node.create({
  name: 'doc',
  topNode: true,
  content: 'paragraph',
})

const extensions = [
  StarterKit.configure({
    document: false,
    heading: false,
    blockquote: false,
    bulletList: false,
    orderedList: false,
    listItem: false,
    listKeymap: false,
    code: false,
    codeBlock: false,
    strike: false,
    underline: false,
    horizontalRule: false,
    trailingNode: false,
    dropcursor: false,
    gapcursor: false,
    link: {
      openOnClick: false,
      protocols: [{ scheme: 'wuhu', optionalSlashes: true }],
    },
  }),
  OneParagraph,
]

const schema = getSchema(extensions)

export function editLink(editor: Editor) {
  const previous = editor.getAttributes('link').href as string | undefined
  const href = globalThis.prompt('Link', previous ?? '')
  if (href == null) return
  const chain = editor.chain().focus().extendMarkRange('link')
  if (href === '') chain.unsetLink().run()
  else chain.setLink({ href }).run()
}

export const typedRuns = (editor: Editor): TextRun[] =>
  runsOf(editor.state.doc.firstChild!)

export function TextEditor({ store, kind, layout, runs, onEditor, onDone }: {
  store: CameraStore
  kind: ItemKind
  layout: SceneText
  runs: TextRun[]
  onEditor(editor: Editor | null): void
  onDone(): void
}) {
  const camera = useCamera(store)
  const editor = useEditor({
    extensions,
    content: schema.nodes.doc.create(
      null,
      schema.nodes.paragraph.create(null, inlineNodes(schema, runs)),
    ).toJSON(),
    autofocus: 'end',
    editorProps: {
      attributes: { spellcheck: 'false', 'aria-label': 'Item text' },
      handleKeyDown: (view, event) => {
        if (event.key !== 'Enter' || event.shiftKey) return false
        view.dispatch(
          view.state.tr.replaceSelectionWith(schema.nodes.hardBreak.create())
            .scrollIntoView(),
        )
        return true
      },
    },
  }, [])
  useEffect(() => {
    onEditor(editor)
    return () => onEditor(null)
  }, [editor])

  const box = viewRect(camera, layout.box)
  return (
    <div
      className='canvas-chrome canvas-text canvas-text-editing'
      data-kind={kind}
      data-alignment={layout.alignment}
      style={{
        left: box.x,
        top: box.y,
        width: layout.box.w,
        height: layout.box.h,
        transform: `scale(${camera.scale})`,
        fontSize: layout.size,
        color: textColor,
      }}
      onKeyDown={(event) => {
        if (event.key === 'Escape') {
          event.preventDefault()
          event.stopPropagation()
          onDone()
        } else if (
          event.key === 'k' && (event.metaKey || event.ctrlKey) &&
          editor !== null
        ) {
          event.preventDefault()
          editLink(editor)
        }
      }}
    >
      <EditorContent editor={editor} />
    </div>
  )
}
