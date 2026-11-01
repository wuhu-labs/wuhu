import {
  type LoroDoc,
  LoroMap,
  LoroText,
  type LoroTreeNode,
  type TreeID,
} from 'loro-crdt/web'
import { configuredDoc } from '../wmd/loro.ts'

// The board of a `.canvas` Loro doc, as plain data. An item or connector
// out of schema is skipped, never repaired; a colour or connector field out
// of schema reads as its default.

export const itemKinds = [
  'sticky',
  'text',
  'rect',
  'ellipse',
  'diamond',
  'section',
  'file',
] as const
export type ItemKind = typeof itemKinds[number]

export const colors = [
  'yellow',
  'pink',
  'green',
  'blue',
  'purple',
  'gray',
] as const
export type CanvasColor = typeof colors[number]

export const sides = ['top', 'right', 'bottom', 'left'] as const
export type Side = typeof sides[number]

export const connectorStyles = ['straight', 'elbow'] as const
export type ConnectorStyle = typeof connectorStyles[number]

export const arrows = ['none', 'end', 'both'] as const
export type Arrow = typeof arrows[number]

export interface TextRun {
  text: string
  bold?: true
  italic?: true
  link?: string
}

export interface BoardItem {
  id: string
  kind: ItemKind
  // The section it sits in; its x and y are relative to that section.
  parent: string | null
  x: number
  y: number
  w: number
  h: number
  color?: CanvasColor
  text: TextRun[]
  path?: string
}

export interface BoardConnector {
  id: string
  from: string
  to: string
  fromSide?: Side
  toSide?: Side
  style: ConnectorStyle
  // How far an elbow's middle segment sits from halfway between its ends.
  offset: number
  arrow: Arrow
  label: TextRun[]
}

// Items in tree order: top-level siblings in order, a section's children
// right after it.
export interface Board {
  items: BoardItem[]
  connectors: BoardConnector[]
}

export const idPattern = /^[0-9a-z]{6}$/

// Every board doc needs it: `.wmd`'s mark expansion, and the tree's sibling
// order, as CanvasSchema.configure sets them.
export function configuredBoard(doc: LoroDoc): LoroDoc {
  configuredDoc(doc).getTree('tree').enableFractionalIndex(0)
  return doc
}

function member<T extends string>(
  values: readonly T[],
  value: unknown,
): T | undefined {
  return values.includes(value as T) ? value as T : undefined
}

function finite(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined
}

function runsOf(value: unknown): TextRun[] | undefined {
  if (value === undefined) return []
  if (!(value instanceof LoroText)) return undefined
  const runs: TextRun[] = []
  for (const { insert, attributes } of value.toDelta()) {
    if (typeof insert !== 'string' || insert === '') continue
    const run: TextRun = { text: insert }
    if (attributes?.bold === true) run.bold = true
    if (attributes?.italic === true) run.italic = true
    if (typeof attributes?.link === 'string') run.link = attributes.link
    runs.push(run)
  }
  return runs
}

function itemOf(meta: LoroMap, parent: string | null): BoardItem | undefined {
  const id = meta.get('id')
  const kind = member(itemKinds, meta.get('kind'))
  const [x, y, w, h] = ['x', 'y', 'w', 'h'].map((key) => finite(meta.get(key)))
  // Free text has no colour; one out of schema reads as none.
  const color = kind === 'text' ? undefined : member(colors, meta.get('color'))
  // Only a file card has a path; one left on another kind is ignored.
  const path = kind === 'file' ? meta.get('path') : undefined
  const text = runsOf(meta.get('text'))
  if (
    typeof id !== 'string' || !idPattern.test(id) || kind === undefined ||
    x === undefined || y === undefined || w === undefined ||
    h === undefined || w < 0 || h < 0 || text === undefined ||
    (kind === 'file' && typeof path !== 'string')
  ) return
  return {
    id,
    kind,
    parent,
    x,
    y,
    w,
    h,
    ...(color === undefined ? {} : { color }),
    text,
    ...(typeof path === 'string' ? { path } : {}),
  }
}

function connectorOf(id: string, value: unknown): BoardConnector | undefined {
  if (!(value instanceof LoroMap) || !idPattern.test(id)) return
  const from = value.get('from')
  const to = value.get('to')
  if (typeof from !== 'string' || typeof to !== 'string') return
  // A field out of schema reads as its default, as CanvasDocument's reader does.
  const fromSide = member(sides, value.get('fromSide'))
  const toSide = member(sides, value.get('toSide'))
  return {
    id,
    from,
    to,
    ...(fromSide === undefined ? {} : { fromSide }),
    ...(toSide === undefined ? {} : { toSide }),
    style: member(connectorStyles, value.get('style')) ?? 'straight',
    offset: finite(value.get('offset')) ?? 0,
    arrow: member(arrows, value.get('arrow')) ?? 'end',
    label: runsOf(value.get('label')) ?? [],
  }
}

export function boardOf(doc: LoroDoc): Board {
  return readBoard(doc).board
}

// The board and the tree node of each item it holds.
export function readBoard(
  doc: LoroDoc,
): { board: Board; nodes: Map<string, TreeID> } {
  const items: BoardItem[] = []
  const nodes = new Map<string, TreeID>()
  const add = (
    item: BoardItem | undefined,
    node: LoroTreeNode,
  ): boolean => {
    if (item === undefined || nodes.has(item.id)) return false
    nodes.set(item.id, node.id)
    items.push(item)
    return true
  }
  for (const node of doc.getTree('tree').roots()) {
    const item = itemOf(node.data, null)
    if (!add(item, node) || item?.kind !== 'section') continue
    for (const child of node.children() ?? [] as LoroTreeNode[]) {
      const inner = itemOf(child.data, item.id)
      if (inner?.kind !== 'section') add(inner, child)
    }
  }
  const ids = nodes
  const connectors: BoardConnector[] = []
  for (const [id, value] of doc.getMap('connectors').entries()) {
    const connector = connectorOf(id, value)
    if (
      connector !== undefined && ids.has(connector.from) &&
      ids.has(connector.to)
    ) connectors.push(connector)
  }
  return { board: { items, connectors }, nodes }
}

// An item's frame in board points.
export function frameOf(board: Board, item: BoardItem) {
  const parent = item.parent === null
    ? undefined
    : board.items.find((other) => other.id === item.parent)
  return {
    x: item.x + (parent?.x ?? 0),
    y: item.y + (parent?.y ?? 0),
    w: item.w,
    h: item.h,
  }
}
