import {
  type LoroDoc,
  LoroMap,
  LoroMovableList,
  LoroText,
  type LoroTree,
  type LoroTreeNode,
  type TreeID,
} from 'loro-crdt/web'
import { noMarks, syncMarks } from '../wmd/binding.ts'
import {
  type BoardConnector,
  type CanvasColor,
  type ItemKind,
  readBoard,
  runsOf,
  type TextRun,
} from './board.ts'
import type { Rect } from './scene.ts'

// CanvasDocument's CanvasEditor, op for op: the shared fixture
// (editor-cases.json) holds both to the same boards.

export type EditErrorKind = 'unknown' | 'notASection' | 'nestedSection'

export class CanvasEditError extends Error {
  constructor(readonly kind: EditErrorKind, readonly id: string) {
    super(`${kind}: ${id}`)
    this.name = 'CanvasEditError'
  }
}

export interface Deletion {
  items: string[]
  connectors: string[]
}

export type NewConnector =
  & Pick<BoardConnector, 'from' | 'to' | 'fromSide' | 'toSide'>
  & Partial<Pick<BoardConnector, 'style' | 'offset' | 'arrow' | 'label'>>

export const defaultSize: Record<ItemKind, { w: number; h: number }> = {
  sticky: { w: 160, h: 160 },
  text: { w: 240, h: 40 },
  rect: { w: 200, h: 100 },
  ellipse: { w: 160, h: 120 },
  diamond: { w: 160, h: 120 },
  section: { w: 600, h: 400 },
  file: { w: 240, h: 160 },
}

export const defaultColor: Record<ItemKind, CanvasColor | null> = {
  sticky: 'yellow',
  rect: 'blue',
  ellipse: 'blue',
  diamond: 'blue',
  section: 'gray',
  text: null,
  file: null,
}

const alphabet = '0123456789abcdefghijklmnopqrstuvwxyz'

// A random draw below `n`.
export type Draw = (n: number) => number

const cryptoDraw: Draw = (n) => {
  const limit = Math.floor(0x1_0000_0000 / n) * n
  const word = new Uint32Array(1)
  do crypto.getRandomValues(word)
  while (word[0] >= limit)
  return word[0] % n
}

export function randomID(taken: Set<string>, draw: Draw = cryptoDraw): string {
  while (true) {
    let id = ''
    for (let i = 0; i < 6; i++) id += alphabet[draw(alphabet.length)]
    if (!taken.has(id)) return id
  }
}

function number(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined
}

// Setters write only what differs, so a no-op edit makes no operation.
function setNumber(map: LoroMap, key: string, value: number) {
  if (number(map.get(key)) !== value) map.set(key, value)
}

function setString(map: LoroMap, key: string, value: string | undefined) {
  if (value === undefined) {
    if (map.get(key) !== undefined) map.delete(key)
  } else if (map.get(key) !== value) map.set(key, value)
}

export function sameRuns(a: TextRun[], b: TextRun[]): boolean {
  return a.length === b.length &&
    a.every((run, i) =>
      run.text === b[i].text && run.bold === b[i].bold &&
      run.italic === b[i].italic && run.link === b[i].link &&
      run.code === b[i].code
    )
}

// Makes the text read `runs`: a refined text diff, then the marks it needs.
export function syncText(text: LoroText, runs: TextRun[]) {
  const plain = runs.map((run) => run.text).join('')
  if (text.toString() !== plain) text.update(plain, { useRefinedDiff: true })
  const marks = noMarks()
  for (const run of runs) {
    for (let i = 0; i < run.text.length; i++) {
      marks.bold.push(run.bold ? true : null)
      marks.italic.push(run.italic ? true : null)
      marks.link.push(run.link ?? null)
      marks.code.push(run.code ? true : null)
    }
  }
  syncMarks(text, marks, plain.length)
}

// A sticky's `text` on this board only draws its blocks, so its copy takes
// the blocks themselves.
function copyBlocks(from: LoroMap, to: LoroMap) {
  const source = from.get('blocks')
  if (!(source instanceof LoroMovableList)) return
  const blocks = to.setContainer('blocks', new LoroMovableList())
  for (let index = 0; index < source.length; index++) {
    const block = source.get(index)
    if (!(block instanceof LoroMap)) continue
    const copy = blocks.pushContainer(new LoroMap())
    for (const key of block.keys()) {
      const value = block.get(key)
      if (value instanceof LoroText) {
        syncText(copy.setContainer(key, new LoroText()), runsOf(value) ?? [])
      } else if (typeof value !== 'object' || value === null) {
        copy.set(key, value)
      }
    }
  }
}

function writeConnector(
  connector: Omit<BoardConnector, 'id'>,
  map: LoroMap,
  current: BoardConnector | undefined,
) {
  setString(map, 'from', connector.from)
  setString(map, 'to', connector.to)
  setString(map, 'fromSide', connector.fromSide)
  setString(map, 'toSide', connector.toSide)
  setString(map, 'style', connector.style)
  setString(map, 'arrow', connector.arrow)
  if (current?.offset !== connector.offset) {
    if (connector.offset === 0) {
      if (map.get('offset') !== undefined) map.delete('offset')
    } else map.set('offset', connector.offset)
  }
  if (current === undefined || !sameRuns(current.label, connector.label)) {
    syncText(
      map.getOrCreateContainer('label', new LoroText()),
      connector.label,
    )
  }
}

// Edits a board's Loro doc in board terms: frames in absolute board points,
// ids are board ids. It only issues operations; the caller commits. It
// indexes the board when made: one per gesture or transaction.
export class CanvasEditor {
  private readonly tree: LoroTree
  private readonly connectors: LoroMap
  private readonly nodes: Map<string, TreeID>
  private readonly taken: Set<string>

  constructor(readonly doc: LoroDoc, private readonly draw?: Draw) {
    this.tree = doc.getTree('tree')
    this.connectors = doc.getMap('connectors')
    this.nodes = readBoard(doc).nodes
    this.taken = new Set(this.connectors.keys())
    for (const node of this.tree.nodes()) {
      const id = node.data.get('id')
      if (typeof id === 'string') this.taken.add(id)
    }
  }

  // A new item on top of its siblings.
  insert(
    kind: ItemKind,
    frame: Rect,
    color: CanvasColor | null,
    { text = [], path, section = null }: {
      text?: TextRun[]
      path?: string
      section?: string | null
    } = {},
  ): string {
    const parent = this.parentFor(kind, section)
    const id = this.newID()
    const node = this.tree.createNode(parent)
    const meta = node.data
    const origin = this.origin(parent)
    meta.set('id', id)
    meta.set('kind', kind)
    meta.set('x', frame.x - origin.x)
    meta.set('y', frame.y - origin.y)
    meta.set('w', frame.w)
    meta.set('h', frame.h)
    if (kind !== 'text' && color !== null) meta.set('color', color)
    if (kind === 'file' && path !== undefined) meta.set('path', path)
    if (text.length > 0) {
      syncText(meta.getOrCreateContainer('text', new LoroText()), text)
    }
    this.nodes.set(id, node.id)
    return id
  }

  // `frame` in board points; the item keeps its section.
  setFrame(id: string, frame: Rect) {
    const node = this.node(id)
    const origin = this.origin(node.parent()?.id)
    setNumber(node.data, 'x', frame.x - origin.x)
    setNumber(node.data, 'y', frame.y - origin.y)
    setNumber(node.data, 'w', frame.w)
    setNumber(node.data, 'h', frame.h)
  }

  // Moves each item by the offset; one inside a moving section rides along.
  move(ids: string[], dx: number, dy: number) {
    const moving = new Set(ids)
    for (const id of moving) {
      const node = this.node(id)
      const parent = node.parent()
      if (parent !== undefined && moving.has(this.idOf(parent.id) ?? '')) {
        continue
      }
      setNumber(node.data, 'x', (number(node.data.get('x')) ?? 0) + dx)
      setNumber(node.data, 'y', (number(node.data.get('y')) ?? 0) + dy)
    }
  }

  // Into `section` (null: the board), on top of its new siblings, where it
  // stands.
  reparent(id: string, section: string | null) {
    const node = this.node(id)
    const meta = node.data
    const kind = meta.get('kind') as ItemKind | undefined
    const parent = this.parentFor(kind ?? 'sticky', section)
    const from = node.parent()?.id
    if (from === parent) return
    const old = this.origin(from)
    const next = this.origin(parent)
    const x = (number(meta.get('x')) ?? 0) + old.x - next.x
    const y = (number(meta.get('y')) ?? 0) + old.y - next.y
    this.tree.move(node.id, parent)
    setNumber(meta, 'x', x)
    setNumber(meta, 'y', y)
  }

  bringToFront(id: string) {
    const node = this.node(id)
    const siblings = node.parent()?.children() ?? this.tree.roots()
    const last = siblings[siblings.length - 1]
    if (last !== undefined && last.id !== node.id) node.moveAfter(last)
  }

  // Deletes the items, a section's contents and every connector touching
  // one of them.
  delete(ids: string[]): Deletion {
    const gone = new Set<string>()
    for (const id of ids) {
      const node = this.node(id)
      for (const child of node.children() ?? []) {
        const inner = this.idOf(child.id)
        if (inner !== undefined) gone.add(inner)
      }
      gone.add(id)
    }
    const items = [...gone].sort()
    const connectors: string[] = []
    for (const key of [...this.connectors.keys()].sort()) {
      const entry = this.connectors.get(key)
      if (!(entry instanceof LoroMap)) continue
      const ends = [entry.get('from'), entry.get('to')]
      if (!ends.some((end) => typeof end === 'string' && gone.has(end))) {
        continue
      }
      this.connectors.delete(key)
      connectors.push(key)
    }
    for (const id of items) {
      const node = this.nodes.get(id)
      if (node === undefined) continue
      this.nodes.delete(id)
      if (!this.tree.isNodeDeleted(node)) this.tree.delete(node)
    }
    return { items, connectors }
  }

  // Copies the items, offset; a section brings its contents, and connectors
  // between copied items come too. Answers each original's copy.
  duplicate(ids: string[], dx: number, dy: number): Map<string, string> {
    const { board } = readBoard(this.doc)
    const chosen = new Set(ids)
    const copies = new Map<string, string>()
    const byId = new Map(board.items.map((item) => [item.id, item]))
    for (const item of board.items) {
      const parentChosen = item.parent !== null && chosen.has(item.parent)
      if (!chosen.has(item.id) && !parentChosen) continue
      const copiedSection = item.parent === null
        ? undefined
        : copies.get(item.parent)
      let frame: Rect
      if (copiedSection !== undefined) {
        const origin = this.origin(this.node(copiedSection).id)
        frame = {
          x: origin.x + item.x,
          y: origin.y + item.y,
          w: item.w,
          h: item.h,
        }
      } else {
        const parent = item.parent === null ? undefined : byId.get(item.parent)
        frame = {
          x: item.x + (parent?.x ?? 0) + dx,
          y: item.y + (parent?.y ?? 0) + dy,
          w: item.w,
          h: item.h,
        }
      }
      const copy = this.insert(item.kind, frame, item.color ?? null, {
        text: item.note ? [] : item.text,
        path: item.path,
        section: copiedSection ?? item.parent,
      })
      if (item.note) copyBlocks(this.node(item.id).data, this.node(copy).data)
      copies.set(item.id, copy)
    }
    for (const connector of board.connectors) {
      const from = copies.get(connector.from)
      const to = copies.get(connector.to)
      if (from === undefined || to === undefined) continue
      this.connect({ ...connector, from, to })
    }
    return copies
  }

  // null clears it; free text takes none.
  setColor(ids: string[], color: CanvasColor | null) {
    for (const id of ids) {
      const meta = this.node(id).data
      if (color !== null && meta.get('kind') !== 'text') {
        setString(meta, 'color', color)
      } else if (meta.get('color') !== undefined) meta.delete('color')
    }
  }

  // Leaving `file` drops the path, so no reader meets a stray one.
  setKind(id: string, kind: ItemKind) {
    const meta = this.node(id).data
    setString(meta, 'kind', kind)
    if (kind !== 'file') setString(meta, 'path', undefined)
  }

  setText(id: string, text: TextRun[]) {
    const meta = this.node(id).data
    syncText(meta.getOrCreateContainer('text', new LoroText()), text)
  }

  setPath(id: string, path: string) {
    setString(this.node(id).data, 'path', path)
  }

  connect(connector: NewConnector): string {
    for (const end of [connector.from, connector.to]) {
      if (!this.nodes.has(end)) throw new CanvasEditError('unknown', end)
    }
    const id = this.newID()
    const map = this.connectors.setContainer(id, new LoroMap())
    writeConnector(
      {
        from: connector.from,
        to: connector.to,
        ...(connector.fromSide === undefined
          ? {}
          : { fromSide: connector.fromSide }),
        ...(connector.toSide === undefined ? {} : { toSide: connector.toSide }),
        style: connector.style ?? 'straight',
        offset: connector.offset ?? 0,
        arrow: connector.arrow ?? 'end',
        label: connector.label ?? [],
      },
      map,
      undefined,
    )
    return id
  }

  // Changes a connector's fields; its id stays.
  updateConnector(id: string, change: (connector: BoardConnector) => void) {
    const map = this.connectors.get(id)
    const current = readBoard(this.doc).board.connectors.find((c) =>
      c.id === id
    )
    if (!(map instanceof LoroMap) || current === undefined) {
      throw new CanvasEditError('unknown', id)
    }
    const next: BoardConnector = { ...current, label: [...current.label] }
    change(next)
    for (const end of [next.from, next.to]) {
      if (!this.nodes.has(end)) throw new CanvasEditError('unknown', end)
    }
    writeConnector(next, map, current)
  }

  deleteConnector(id: string) {
    if (this.connectors.get(id) === undefined) {
      throw new CanvasEditError('unknown', id)
    }
    this.connectors.delete(id)
  }

  private newID(): string {
    const id = randomID(this.taken, this.draw)
    this.taken.add(id)
    return id
  }

  private node(id: string): LoroTreeNode {
    const tree = this.nodes.get(id)
    const node = tree === undefined ? undefined : this.tree.getNodeByID(tree)
    if (node === undefined) throw new CanvasEditError('unknown', id)
    return node
  }

  private idOf(node: TreeID): string | undefined {
    for (const [id, tree] of this.nodes) if (tree === node) return id
    return undefined
  }

  private parentFor(
    kind: ItemKind,
    section: string | null,
  ): TreeID | undefined {
    if (section === null) return undefined
    if (kind === 'section') throw new CanvasEditError('nestedSection', section)
    const node = this.node(section)
    if (node.data.get('kind') !== 'section' || node.parent() !== undefined) {
      throw new CanvasEditError('notASection', section)
    }
    return node.id
  }

  private origin(parent: TreeID | undefined): { x: number; y: number } {
    if (parent === undefined) return { x: 0, y: 0 }
    const meta = this.tree.getNodeByID(parent)?.data
    return {
      x: number(meta?.get('x')) ?? 0,
      y: number(meta?.get('y')) ?? 0,
    }
  }
}
