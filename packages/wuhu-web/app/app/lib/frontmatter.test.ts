import {
  attrValue,
  editableDocument,
  joinEditable,
  splitFrontmatter,
} from './frontmatter.ts'

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

Deno.test('splitFrontmatter drops a closed block and keeps the body', () => {
  assertEquals(
    splitFrontmatter('---\nkind: note\nstatus: draft\n---\n# Title\n\nBody'),
    {
      frontmatter: true,
      head: '---\nkind: note\nstatus: draft\n---\n',
      body: '# Title\n\nBody',
    },
  )
})

Deno.test('splitFrontmatter accepts the YAML document terminator', () => {
  assertEquals(
    splitFrontmatter('---\nkind: note\n...\nBody'),
    { frontmatter: true, head: '---\nkind: note\n...\n', body: 'Body' },
  )
})

Deno.test('splitFrontmatter normalises CRLF and strips a BOM', () => {
  assertEquals(
    splitFrontmatter('﻿---\r\nkind: note\r\n---\r\nBody\r\nmore'),
    { frontmatter: true, head: '---\nkind: note\n---\n', body: 'Body\nmore' },
  )
})

Deno.test('splitFrontmatter leaves a document without frontmatter alone', () => {
  const content = '# Title\n\n---\n\nA rule, not frontmatter.'
  assertEquals(splitFrontmatter(content), {
    frontmatter: false,
    head: '',
    body: content,
  })
})

Deno.test('splitFrontmatter leaves an unterminated block as body text', () => {
  const content = '---\nkind: note\n\nstill going'
  assertEquals(splitFrontmatter(content), {
    frontmatter: false,
    head: '',
    body: content,
  })
})

Deno.test('splitFrontmatter yields an empty body for a frontmatter-only doc', () => {
  assertEquals(
    splitFrontmatter('---\nkind: note\n---'),
    { frontmatter: true, head: '---\nkind: note\n---\n', body: '' },
  )
})

Deno.test('editableDocument hands the editor the blocks between the newlines', () => {
  assertEquals(
    editableDocument('---\nname: data-views\n---\n\n# Data views\n\nBody\n'),
    {
      before: '---\nname: data-views\n---\n\n',
      body: '# Data views\n\nBody',
      after: '\n',
    },
  )
  assertEquals(editableDocument('\n\n'), {
    before: '\n\n',
    body: '',
    after: '',
  })
})

Deno.test('joinEditable puts an edited body back between the newlines', () => {
  const document = editableDocument('---\nkind: note\n---\n\nold\n')
  assertEquals(joinEditable(document, 'new'), '---\nkind: note\n---\n\nnew\n')
  assertEquals(joinEditable(editableDocument('plain'), 'new'), 'new')
})

Deno.test('joinEditable leaves spaces to the editor, which writes them', () => {
  const code = editableDocument('---\nkind: note\n---\n\n    code\n')
  assertEquals(code.body, '    code')
  assertEquals(
    joinEditable(code, '```\ncode\n```'),
    '---\nkind: note\n---\n\n```\ncode\n```\n',
  )
  const trailing = editableDocument('Para  \n')
  assertEquals(joinEditable(trailing, 'Para'), 'Para\n')
  assertEquals(joinEditable(trailing, 'Para!'), 'Para!\n')
})

Deno.test('attrValue unwraps JSON scalars and keeps objects as JSON', () => {
  assertEquals(attrValue('"2026-03-04"'), {
    kind: 'scalar',
    text: '2026-03-04',
  })
  assertEquals(attrValue('42'), { kind: 'scalar', text: '42' })
  assertEquals(attrValue('true'), { kind: 'scalar', text: 'true' })
  assertEquals(attrValue('null'), { kind: 'scalar', text: 'null' })
  assertEquals(attrValue('{"strategy":"incr"}'), {
    kind: 'json',
    text: '{\n  "strategy": "incr"\n}',
  })
})

Deno.test('attrValue falls back to the raw text when it is not JSON', () => {
  assertEquals(attrValue('bare text'), { kind: 'scalar', text: 'bare text' })
})
