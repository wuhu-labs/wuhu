import { GlobalRegistrator } from '@happy-dom/global-registrator'
import { Editor } from '@tiptap/core'
import { DOMParser as ProseMirrorDOMParser, Schema } from '@tiptap/pm/model'
import { marked } from 'marked'
import { renderToStaticMarkup } from 'react-dom/server'
import { MemoryRouter, Outlet, Route, Routes } from 'react-router'
import {
  markdownEditorOptions,
  setEditable,
} from '../components/markdown-editor.ts'
import { Markdown } from '../components/markdown-view.tsx'
import cases from './markdown-cjk-cases.json' with { type: 'json' }

function view(source: string): string {
  return renderToStaticMarkup(
    <MemoryRouter>
      <Routes>
        <Route
          element={<Outlet context={{ group: 'shared', contentHost: null }} />}
        >
          <Route path='/' element={<Markdown>{source}</Markdown>} />
        </Route>
      </Routes>
    </MemoryRouter>,
  )
}

function normalized(html: string): string {
  return html.replace(/&ZeroWidthSpace;/g, '\u200b').replace(/&quot;/g, '"')
    .replace(/&#(?:x27|39);/g, "'")
    .replace(/\n/g, '').replace(/<a [^>]*>/g, '<a>')
}

Deno.test('web reader and editor import upstream CJK-friendly examples', async () => {
  GlobalRegistrator.register()
  try {
    for (const { source, html } of cases) {
      const actual = view(source)
      if (normalized(actual) !== normalized(html)) {
        throw new Error(`reader: ${source}\n${actual}\nexpected ${html}`)
      }
      const editor = new Editor(markdownEditorOptions(source, false, () => {
        throw new Error('import must not write back')
      }))
      const expectedHTML = new DOMParser().parseFromString(html, 'text/html')
      // Markdown import supports bold/italic around code even though Tiptap's
      // default HTML importer excludes those marks. Preserve them in the oracle.
      const schema = new Schema({
        nodes: editor.schema.spec.nodes,
        marks: editor.schema.spec.marks.update('code', {
          ...editor.schema.spec.marks.get('code'),
          excludes: '',
        }),
      })
      const expected = ProseMirrorDOMParser.fromSchema(schema).parse(
        expectedHTML.body,
      )
      // Tiptap's existing text decoder leaves this named entity literal. Compare
      // its spelling canonically without dropping any text nodes or mark spans.
      const imported = JSON.stringify(editor.getJSON()).replaceAll(
        '&ZeroWidthSpace;',
        '\u200b',
      )
      if (imported !== JSON.stringify(expected.toJSON())) {
        throw new Error(
          `editor: ${source}\n${JSON.stringify(editor.getJSON())}\nexpected ${
            JSON.stringify(expected.toJSON())
          }`,
        )
      }
      editor.destroy()
    }
  } finally {
    await GlobalRegistrator.unregister()
  }
})

Deno.test('CJK imports stay byte-identical until an edit and code/escapes stay literal', () => {
  for (
    const source of [
      '**空间（space）**是',
      '**中文**text',
      '~~中文（text）~~是',
      '**C#**や**F#**は**「.NET」**というプラットフォーム上で動作します。',
    ]
  ) {
    const changes: string[] = []
    const editor = new Editor(
      markdownEditorOptions(
        source + '\r\n',
        false,
        (value) => changes.push(value),
      ),
    )
    if (!view(source).match(/<(strong|del)>/)) throw new Error(source)
    setEditable(editor, true)
    setEditable(editor, false)
    if (changes.length) {
      throw new Error('opening changed the original bytes')
    }
    if (editor.state.doc.firstChild?.type.name !== 'paragraph') {
      throw new Error('CJK paragraph must remain editable, not an atom')
    }
    setEditable(editor, true)
    editor.commands.insertContentAt(editor.state.doc.content.size - 1, {
      type: 'text',
      text: '!',
    })
    if (changes.length !== 1 || !changes[0].endsWith('!')) {
      throw new Error('real edit did not reach the document callback')
    }
    editor.destroy()
  }
  for (
    const source of [
      '`**空间（space）**是`',
      '\\*\\*空间（space）\\*\\*是',
      '&#42;&#42;空间（space）&#42;&#42;是',
    ]
  ) {
    if (view(source).includes('<strong>')) throw new Error(source)
  }
})

Deno.test('editor CJK parsing does not mutate the global marked parser', () => {
  const source = '**中文（text）**是'
  const extension = markdownEditorOptions(source, false, () => {}).extensions
    ?.find((extension) => extension.name === 'markdown')
  const parser: typeof marked = extension?.options.marked
  if (!parser) throw new Error('missing isolated markdown parser')
  for (const options of [undefined, parser.defaults]) {
    const html = parser.parser(parser.lexer(source, options))
    if (html !== '<p><strong>中文（text）</strong>是</p>\n') {
      throw new Error(
        'instance lexer lost CJK defaults or used the global parser',
      )
    }
  }

  if (marked.parse(source) !== '<p>**中文（text）**是</p>\n') {
    throw new Error('editor extension leaked into marked singleton')
  }
})
