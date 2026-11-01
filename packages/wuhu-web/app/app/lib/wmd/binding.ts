import type {
  ContainerID,
  Cursor,
  Delta,
  LoroDoc,
  LoroMap,
  LoroMovableList,
  LoroText,
} from 'loro-crdt/web'
import { LoroMap as Map_, LoroText as Text_ } from 'loro-crdt/web'
import type { Mark, Node as PMNode, Schema } from '@tiptap/pm/model'
import { listNode, type ListStyle, viewNode } from './schema.ts'

export type BlockKind =
  | 'h1'
  | 'h2'
  | 'h3'
  | 'paragraph'
  | 'code'
  | 'list'
  | 'view'

export class WmdDocumentError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'WmdDocumentError'
  }
}

const markKeys = ['bold', 'italic', 'link'] as const
type MarkKey = typeof markKeys[number]
type MarkValue = string | true

export function blocksOf(doc: LoroDoc): LoroMovableList {
  return doc.getMovableList('blocks')
}

function blockAt(blocks: LoroMovableList, index: number): LoroMap {
  const block = blocks.get(index)
  if (!(block instanceof Map_)) {
    throw new WmdDocumentError(`block ${index} is not a map`)
  }
  return block
}

function textOf(block: LoroMap): LoroText {
  const text = block.get('text')
  if (!(text instanceof Text_)) {
    throw new WmdDocumentError(`block ${block.id} has no text`)
  }
  return text
}

function kindOf(node: PMNode): BlockKind {
  switch (node.type.name) {
    case 'heading':
      return `h${node.attrs.level as 1 | 2 | 3}`
    case 'paragraph':
      return 'paragraph'
    case 'codeBlock':
      return 'code'
    case listNode:
      return 'list'
    case viewNode:
      return 'view'
  }
  throw new WmdDocumentError(`no block kind for ${node.type.name}`)
}

// ---- Loro → ProseMirror ----

function marksOf(
  schema: Schema,
  attributes: Record<string, unknown> | undefined,
): Mark[] {
  const marks: Mark[] = []
  if (attributes == null) return marks
  if (attributes.bold === true) marks.push(schema.marks.bold.create())
  if (attributes.italic === true) marks.push(schema.marks.italic.create())
  if (typeof attributes.link === 'string') {
    marks.push(schema.marks.link.create({ href: attributes.link }))
  }
  return marks
}

function inlineOf(schema: Schema, delta: Delta<string>[]): PMNode[] {
  const nodes: PMNode[] = []
  for (const op of delta) {
    if (op.insert == null) continue
    const marks = marksOf(schema, op.attributes)
    op.insert.split('\n').forEach((segment, index) => {
      if (index > 0) nodes.push(schema.nodes.hardBreak.create())
      if (segment !== '') nodes.push(schema.text(segment, marks))
    })
  }
  return nodes
}

function nodeOf(schema: Schema, block: LoroMap): PMNode {
  const blockId = block.id
  const kind = block.get('kind') as BlockKind
  switch (kind) {
    case 'h1':
    case 'h2':
    case 'h3':
      return schema.nodes.heading.create(
        { blockId, level: Number(kind[1]) },
        inlineOf(schema, textOf(block).toDelta()),
      )
    case 'paragraph':
      return schema.nodes.paragraph.create(
        { blockId },
        inlineOf(schema, textOf(block).toDelta()),
      )
    case 'list':
      return schema.nodes[listNode].create(
        {
          blockId,
          level: Number(block.get('level') ?? 0),
          style: (block.get('style') ?? 'unordered') as ListStyle,
        },
        inlineOf(schema, textOf(block).toDelta()),
      )
    case 'code': {
      const text = textOf(block).toString()
      return schema.nodes.codeBlock.create(
        { blockId },
        text === '' ? [] : [schema.text(text)],
      )
    }
    case 'view':
      return schema.nodes[viewNode].create({
        blockId,
        view: block.get('view'),
        config: block.get('config') ?? null,
        sql: block.get('sql') ?? '',
      })
  }
  throw new WmdDocumentError(`unknown block kind ${JSON.stringify(kind)}`)
}

// An empty document still shows one paragraph to type into; it becomes a
// block on its first edit.
export function blockNodes(schema: Schema, doc: LoroDoc): PMNode[] {
  const blocks = blocksOf(doc)
  const nodes: PMNode[] = []
  for (let index = 0; index < blocks.length; index++) {
    nodes.push(nodeOf(schema, blockAt(blocks, index)))
  }
  if (nodes.length === 0) nodes.push(schema.nodes.paragraph.create())
  return nodes
}

export function docOf(schema: Schema, doc: LoroDoc): PMNode {
  return schema.topNodeType.create(null, blockNodes(schema, doc))
}

// ---- ProseMirror → Loro ----

interface Flat {
  text: string
  marks: Record<MarkKey, (MarkValue | null)[]>
}

function flatten(node: PMNode): Flat {
  let text = ''
  const marks: Flat['marks'] = { bold: [], italic: [], link: [] }
  const push = (chunk: string, values: Record<MarkKey, MarkValue | null>) => {
    text += chunk
    for (const key of markKeys) {
      for (let i = 0; i < chunk.length; i++) marks[key].push(values[key])
    }
  }
  node.forEach((child) => {
    if (child.type.name === 'hardBreak') {
      push('\n', { bold: null, italic: null, link: null })
      return
    }
    if (!child.isText || child.text == null) return
    const has = (name: string) => child.marks.find((m) => m.type.name === name)
    const link = has('link')
    push(child.text, {
      bold: has('bold') ? true : null,
      italic: has('italic') ? true : null,
      link: link ? String(link.attrs.href) : null,
    })
  })
  return { text, marks }
}

function isHighSurrogate(code: number) {
  return code >= 0xd800 && code <= 0xdbff
}

function syncString(text: LoroText, next: string) {
  const current = text.toString()
  if (current === next) return
  let start = 0
  const limit = Math.min(current.length, next.length)
  while (start < limit && current[start] === next[start]) start++
  if (start > 0 && isHighSurrogate(current.charCodeAt(start - 1))) start--
  let end = 0
  while (
    end < limit - start &&
    current[current.length - 1 - end] === next[next.length - 1 - end]
  ) end++
  if (
    end > 0 && isHighSurrogate(current.charCodeAt(current.length - end - 1))
  ) {
    end--
  }
  const removed = current.length - start - end
  if (removed > 0) text.delete(start, removed)
  const inserted = next.slice(start, next.length - end)
  if (inserted !== '') text.insert(start, inserted)
}

function currentMarks(text: LoroText, length: number): Flat['marks'] {
  const marks: Flat['marks'] = { bold: [], italic: [], link: [] }
  for (const op of text.toDelta()) {
    if (op.insert == null) continue
    const attributes = op.attributes ?? {}
    for (const key of markKeys) {
      const value = attributes[key]
      const normal = value == null || value === false
        ? null
        : key === 'link'
        ? String(value)
        : true
      for (let i = 0; i < op.insert.length; i++) marks[key].push(normal)
    }
  }
  for (const key of markKeys) marks[key].length = length
  return marks
}

function syncMarks(text: LoroText, wanted: Flat['marks'], length: number) {
  const have = currentMarks(text, length)
  for (const key of markKeys) {
    let index = 0
    while (index < length) {
      const want = wanted[key][index] ?? null
      if (want === (have[key][index] ?? null)) {
        index++
        continue
      }
      let end = index + 1
      while (
        end < length && (wanted[key][end] ?? null) === want &&
        (have[key][end] ?? null) !== want
      ) end++
      if (want == null) text.unmark({ start: index, end }, key)
      else text.mark({ start: index, end }, key, want)
      index = end
    }
  }
}

function writeBlock(block: LoroMap, node: PMNode) {
  const kind = kindOf(node)
  if (block.get('kind') !== kind) block.set('kind', kind)
  if (kind === 'list') {
    if (Number(block.get('level')) !== node.attrs.level) {
      block.set('level', node.attrs.level)
    }
    if (block.get('style') !== node.attrs.style) {
      block.set('style', node.attrs.style)
    }
  } else {
    if (block.get('level') !== undefined) block.delete('level')
    if (block.get('style') !== undefined) block.delete('style')
  }
  if (kind === 'view') {
    if (block.get('view') !== node.attrs.view) {
      block.set('view', node.attrs.view)
    }
    if (block.get('sql') !== node.attrs.sql) block.set('sql', node.attrs.sql)
    if (
      JSON.stringify(block.get('config') ?? null) !==
        JSON.stringify(node.attrs.config)
    ) block.set('config', node.attrs.config)
    return
  }
  const existing = block.get('text')
  const text = existing instanceof Text_
    ? existing
    : block.setContainer('text', new Text_())
  const flat = flatten(node)
  syncString(text, flat.text)
  if (kind === 'code') {
    syncMarks(text, { bold: [], italic: [], link: [] }, flat.text.length)
  } else syncMarks(text, flat.marks, flat.text.length)
}

function idOf(node: PMNode): ContainerID | null {
  return (node.attrs.blockId as ContainerID | null) ?? null
}

// Pairs each block ProseMirror made without a live id with a vanished Loro
// block between the same surviving neighbours, so a block that changed kind
// (an input rule, a setBlockType) keeps its identity and its peers' cursors.
function plan(
  live: ContainerID[],
  wanted: (ContainerID | null)[],
): (ContainerID | null)[] {
  const liveSet = new Set(live)
  const seen = new Set<ContainerID>()
  const claimed = wanted.map((id) => {
    if (id == null || !liveSet.has(id) || seen.has(id)) return null
    seen.add(id)
    return id
  })
  const anchors = new Set(claimed.filter((id) => id != null))
  const vanishedByGap = new Map<number, ContainerID[]>()
  let gap = 0
  for (const id of live) {
    if (anchors.has(id)) {
      gap++
      continue
    }
    const list = vanishedByGap.get(gap) ?? []
    list.push(id)
    vanishedByGap.set(gap, list)
  }
  gap = 0
  return claimed.map((id) => {
    if (id != null) {
      gap++
      return id
    }
    return vanishedByGap.get(gap)?.shift() ?? null
  })
}

// Makes the Loro blocks equal the ProseMirror document. Returns the ids of
// blocks ProseMirror does not know yet, by top-level index.
export function writeDocument(
  doc: LoroDoc,
  before: PMNode,
  after: PMNode,
): Map<number, ContainerID> {
  const blocks = blocksOf(doc)
  const live: ContainerID[] = []
  for (let index = 0; index < blocks.length; index++) {
    live.push(blockAt(blocks, index).id)
  }
  const nodes: PMNode[] = []
  after.forEach((node) => nodes.push(node))
  const target = plan(live, nodes.map(idOf))
  const kept = new Set(target.filter((id) => id != null))
  for (let index = live.length - 1; index >= 0; index--) {
    if (!kept.has(live[index])) blocks.delete(index, 1)
  }
  const previous = new Map<ContainerID, PMNode>()
  before.forEach((node) => {
    const id = idOf(node)
    if (id != null) previous.set(id, node)
  })
  const assigned = new Map<number, ContainerID>()
  nodes.forEach((node, index) => {
    const id = target[index]
    let block: LoroMap
    if (id == null) {
      block = blocks.insertContainer(index, new Map_())
    } else {
      let at = index
      while (blockAt(blocks, at).id !== id) at++
      if (at !== index) blocks.move(at, index)
      block = blockAt(blocks, index)
      if (id === idOf(node) && previous.get(id)?.eq(node)) return
    }
    writeBlock(block, node)
    if (block.id !== idOf(node)) assigned.set(index, block.id)
  })
  return assigned
}

// ---- positions and stable cursors ----

function blockIndex(blocks: LoroMovableList, id: ContainerID): number {
  for (let index = 0; index < blocks.length; index++) {
    if (blockAt(blocks, index).id === id) return index
  }
  return -1
}

export function blockStart(pm: PMNode, index: number): number {
  let pos = 0
  for (let i = 0; i < index; i++) pos += pm.child(i).nodeSize
  return pos
}

// A stable cursor for a ProseMirror position, on the text of the block it is
// in; none for a position on a view block or a block not yet in Loro.
export function cursorAt(
  doc: LoroDoc,
  pm: PMNode,
  pos: number,
): Cursor | undefined {
  const $pos = pm.resolve(pos)
  if ($pos.depth < 1) return undefined
  const node = $pos.node(1)
  const id = idOf(node)
  if (id == null || !node.isTextblock) return undefined
  const blocks = blocksOf(doc)
  const index = $pos.index(0)
  if (index >= blocks.length || blockAt(blocks, index).id !== id) {
    return undefined
  }
  return textOf(blockAt(blocks, index)).getCursor($pos.parentOffset)
}

// The ProseMirror position a stable cursor points at now, given that `pm`
// shows the Loro document as it stands.
export function positionOf(
  doc: LoroDoc,
  pm: PMNode,
  cursor: Cursor,
): number | undefined {
  const resolved = doc.getCursorPos(cursor)
  if (resolved == null) return undefined
  const text = doc.getContainerById(cursor.containerId())
  const block = text?.parent()
  if (block == null) return undefined
  const index = blockIndex(blocksOf(doc), block.id)
  if (index < 0 || index >= pm.childCount) return undefined
  const node = pm.child(index)
  return blockStart(pm, index) + 1 +
    Math.min(resolved.offset, node.content.size)
}
