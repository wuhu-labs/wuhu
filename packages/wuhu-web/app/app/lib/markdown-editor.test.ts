import { Editor } from '@tiptap/core'
import {
  markdownEditorOptions,
  setEditable,
} from '../components/markdown-editor.ts'
import { documentState, editDocument } from './document-sync.ts'
import { editableDocument, joinEditable } from './frontmatter.ts'

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

const skill = [
  '---',
  'name: data-views',
  'description: Author *.view documents.',
  '---',
  '',
  '# Data views',
  '',
  'A data view is a document, not a feature.',
  '',
  '- `sql` — a SELECT',
  '- `view` — the discriminator',
  '',
].join('\n')

// Soft-wrapped lines and `*` bullets, which the editor writes back
// differently, so only a real edit may reach the draft.
const reformatted = [
  '# Notes',
  '',
  'A paragraph wrapped',
  'across two lines.',
  '',
  '* first',
  '* second',
  '',
].join('\n')

function open(content: string) {
  const document = editableDocument(content)
  const changes: string[] = []
  const editor = new Editor(
    markdownEditorOptions(document.body, false, (markdown) => {
      changes.push(markdown)
    }),
  )
  const state = () =>
    changes.reduce(
      (current, markdown) =>
        editDocument(current, joinEditable(document, markdown)),
      documentState({ token: '1', content }),
    )
  return { document, changes, editor, state }
}

Deno.test('an unchanged document the editor rewrites stays clean on open and on Edit/Preview', () => {
  const { changes, editor, state } = open(reformatted)
  if (editor.getMarkdown() === editableDocument(reformatted).body) {
    throw new Error('fixture no longer differs after a round trip')
  }
  setEditable(editor, true)
  setEditable(editor, false)
  assertEquals(changes, [])
  assertEquals(state().phase, 'clean')
  editor.destroy()
})

Deno.test('a real edit reaches the draft', () => {
  const { changes, editor, state } = open(reformatted)
  setEditable(editor, true)
  editor.commands.insertContentAt(editor.state.doc.content.size - 1, {
    type: 'text',
    text: '!',
  })
  assertEquals(changes.length, 1)
  assertEquals(state().phase, 'dirty')
  editor.destroy()
})

Deno.test('a document the editor has not changed joins back to its own text', () => {
  const { document, editor } = open(skill)
  assertEquals(joinEditable(document, editor.getMarkdown()), skill)
  editor.destroy()
})
