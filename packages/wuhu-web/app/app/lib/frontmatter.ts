// The space indexes frontmatter server-side (DocIndex) and exposes the result
// through the docs / doc_custom_attrs tables. The client only has to agree on
// where the document body starts, so this mirrors DocIndex.splitFrontmatter
// exactly: BOM stripped, CRLF normalised, a leading `---`, closed by `---` or
// `...`. An unterminated block is not frontmatter and stays body text.
export interface SplitDocument {
  frontmatter: boolean
  head: string
  body: string
}

export function splitFrontmatter(content: string): SplitDocument {
  const stripped = content.startsWith('﻿') ? content.slice(1) : content
  const normalized = stripped.replaceAll('\r\n', '\n').replaceAll('\r', '\n')
  const lines = normalized.split('\n')
  if (lines[0] !== '---') return { frontmatter: false, head: '', body: content }

  const close = lines.findIndex(
    (line, index) => index > 0 && (line === '---' || line === '...'),
  )
  if (close === -1) return { frontmatter: false, head: '', body: content }
  return {
    frontmatter: true,
    head: lines.slice(0, close + 1).join('\n') + '\n',
    body: lines.slice(close + 1).join('\n'),
  }
}

// The editor holds the blocks between the frontmatter and the trailing
// newlines. The newlines around them belong to the document and survive an
// edit; spaces and tabs are the blocks' own, since the editor writes them.
export interface EditableDocument {
  before: string
  body: string
  after: string
}

export function editableDocument(content: string): EditableDocument {
  const { head, body } = splitFrontmatter(content)
  const blocks = body.replace(/^\n+/, '')
  const trimmed = blocks.replace(/\n+$/, '')
  return {
    before: head + body.slice(0, body.length - blocks.length),
    body: trimmed,
    after: blocks.slice(trimmed.length),
  }
}

export function joinEditable(document: EditableDocument, body: string): string {
  return document.before + body + document.after
}

// doc_custom_attrs stores each value as JSON text, one row per element for a
// YAML sequence. Objects stay JSON; scalars render as themselves.
export type AttrValue =
  | { kind: 'scalar'; text: string }
  | { kind: 'json'; text: string }

export function attrValue(raw: string): AttrValue {
  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    return { kind: 'scalar', text: raw }
  }
  if (parsed === null) return { kind: 'scalar', text: 'null' }
  if (typeof parsed === 'object') {
    return { kind: 'json', text: JSON.stringify(parsed, null, 2) }
  }
  return { kind: 'scalar', text: String(parsed) }
}
