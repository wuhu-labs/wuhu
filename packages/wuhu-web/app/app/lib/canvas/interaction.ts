import { type Board, type ItemKind, type Side, sides } from './board.ts'
import { contains, intersects } from './grid.ts'
import {
  anchor,
  type CanvasScene,
  type Point,
  type Rect,
  type SceneConnector,
  type SceneItem,
} from './scene.ts'

// What the editing chrome hits and draws, as native's LiveCanvas and
// BoardChrome do: lengths are view points unless they say board.

export type Tool = 'select' | 'connector' | ItemKind

export const tools: readonly Tool[] = [
  'select',
  'sticky',
  'text',
  'rect',
  'ellipse',
  'diamond',
  'connector',
  'section',
  'file',
]

export const chrome = {
  corner: 9,
  side: 11,
  end: 10,
  sideOffset: 16,
  hitSlop: 7,
  pinRadius: 18,
  clickSlop: 4,
  toolStripClearance: 54,
  // Board points.
  minimumSize: 24,
  duplicateOffset: 24,
} as const

export interface Selection {
  items: readonly string[]
  connector: string | null
}

export const noSelection: Selection = { items: [], connector: null }

export type Corner = 'topLeft' | 'topRight' | 'bottomLeft' | 'bottomRight'
export type End = 'from' | 'to'

export type Handle =
  | { kind: 'corner'; id: string; corner: Corner; at: Point }
  | { kind: 'side'; id: string; side: Side; at: Point }
  | { kind: 'end'; connector: string; end: End; at: Point }
  | { kind: 'wiggle'; connector: string; vertical: boolean; at: Point }

const distance = (a: Point, b: Point) => Math.hypot(a.x - b.x, a.y - b.y)

const inside = (r: Rect, p: Point) =>
  p.x >= r.x && p.x <= r.x + r.w && p.y >= r.y && p.y <= r.y + r.h

export const withinClick = (start: Point, end: Point, scale: number) =>
  Math.hypot(end.x - start.x, end.y - start.y) * scale <= chrome.clickSlop

export function rectBetween(a: Point, b: Point): Rect {
  return {
    x: Math.min(a.x, b.x),
    y: Math.min(a.y, b.y),
    w: Math.abs(a.x - b.x),
    h: Math.abs(a.y - b.y),
  }
}

// The middle segment of a four-point elbow; dragging it moves the offset.
export function wiggleOf(
  points: readonly Point[],
): { at: Point; vertical: boolean } | null {
  if (points.length !== 4) return null
  const [, a, b] = points
  return {
    at: { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 },
    vertical: a.x === b.x,
  }
}

export function handlesOf(
  scene: CanvasScene,
  selection: Selection,
  scale: number,
): Handle[] {
  if (selection.connector !== null) {
    const id = selection.connector
    const connector = scene.connectors.find((c) => c.id === id)
    if (connector === undefined) return []
    const handles: Handle[] = [
      { kind: 'end', connector: id, end: 'from', at: connector.points[0] },
      { kind: 'end', connector: id, end: 'to', at: connector.points.at(-1)! },
    ]
    const wiggle = wiggleOf(connector.points)
    if (wiggle !== null) {
      handles.push({ kind: 'wiggle', connector: id, ...wiggle })
    }
    return handles
  }
  if (selection.items.length !== 1) return []
  const item = scene.items.find((i) => i.id === selection.items[0])
  if (item === undefined) return []
  const { id, frame: r } = item
  const pad = 2 / scale
  const off = chrome.sideOffset / scale
  const left = r.x - pad
  const right = r.x + r.w + pad
  const top = r.y - pad
  const bottom = r.y + r.h + pad
  const mid = { x: r.x + r.w / 2, y: r.y + r.h / 2 }
  return [
    { kind: 'side', id, side: 'top', at: { x: mid.x, y: r.y - off } },
    { kind: 'side', id, side: 'right', at: { x: r.x + r.w + off, y: mid.y } },
    { kind: 'side', id, side: 'bottom', at: { x: mid.x, y: r.y + r.h + off } },
    { kind: 'side', id, side: 'left', at: { x: r.x - off, y: mid.y } },
    { kind: 'corner', id, corner: 'topLeft', at: { x: left, y: top } },
    { kind: 'corner', id, corner: 'topRight', at: { x: right, y: top } },
    { kind: 'corner', id, corner: 'bottomLeft', at: { x: left, y: bottom } },
    { kind: 'corner', id, corner: 'bottomRight', at: { x: right, y: bottom } },
  ]
}

function reach(handle: Handle): number {
  switch (handle.kind) {
    case 'corner':
      return chrome.corner / 2 + chrome.hitSlop
    case 'side':
      return chrome.side / 2 + chrome.hitSlop
    case 'end':
      return chrome.end / 2 + chrome.hitSlop + 2
    case 'wiggle':
      return chrome.end / 2 + chrome.hitSlop
  }
}

export function handleAt(
  handles: readonly Handle[],
  p: Point,
  scale: number,
): Handle | null {
  let best: Handle | null = null
  let bestDistance = Infinity
  for (const handle of handles) {
    const d = distance(handle.at, p)
    if (d <= reach(handle) / scale && d < bestDistance) {
      best = handle
      bestDistance = d
    }
  }
  return best
}

// Topmost first: the scene paints sections under everything else.
export function itemAt(
  scene: CanvasScene,
  p: Point,
  accept: (item: SceneItem) => boolean = () => true,
): SceneItem | null {
  for (let i = scene.items.length - 1; i >= 0; i--) {
    const item = scene.items[i]
    if (accept(item) && inside(item.frame, p)) return item
  }
  return null
}

function segmentDistance(p: Point, a: Point, b: Point): number {
  const dx = b.x - a.x
  const dy = b.y - a.y
  const length = dx * dx + dy * dy
  const t = length === 0
    ? 0
    : Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
  return distance(p, { x: a.x + t * dx, y: a.y + t * dy })
}

export function connectorAt(
  scene: CanvasScene,
  p: Point,
  scale: number,
): SceneConnector | null {
  for (let i = scene.connectors.length - 1; i >= 0; i--) {
    const connector = scene.connectors[i]
    const slop = (chrome.hitSlop + connector.stroke.width / 2) / scale
    const { points } = connector
    for (let j = 1; j < points.length; j++) {
      if (segmentDistance(p, points[j - 1], points[j]) <= slop) {
        return connector
      }
    }
  }
  return null
}

export type Hit = { item: SceneItem } | { connector: SceneConnector }

// An item over a connector, a connector over the section it crosses.
export function hitAt(scene: CanvasScene, p: Point, scale: number): Hit | null {
  const item = itemAt(scene, p, (i) => i.kind !== 'section')
  if (item !== null) return { item }
  const connector = connectorAt(scene, p, scale)
  if (connector !== null) return { connector }
  const section = itemAt(scene, p, (i) => i.kind === 'section')
  return section === null ? null : { item: section }
}

export interface Target {
  id: string
  side: Side | null
}

// Where a connector end dropped at `p` attaches: the topmost item there,
// pinned to a side whose midpoint is within reach.
export function targetAt(
  scene: CanvasScene,
  p: Point,
  scale: number,
  exclude: string,
): Target | null {
  const item = itemAt(scene, p, (i) => i.id !== exclude)
  if (item === null) return null
  let side: Side | null = null
  let best = chrome.pinRadius / scale
  for (const s of sides) {
    const d = distance(anchor(item.frame, s), p)
    if (d <= best) {
      best = d
      side = s
    }
  }
  return { id: item.id, side }
}

// Touched items; a section only when the marquee holds all of it.
export function marqueeHits(scene: CanvasScene, marquee: Rect): string[] {
  return scene.items.filter((item) =>
    item.kind === 'section'
      ? contains(marquee, item.frame)
      : intersects(marquee, item.frame)
  ).map((item) => item.id)
}

export function sectionUnder(
  scene: CanvasScene,
  p: Point,
  exclude: string,
): string | null {
  return itemAt(scene, p, (i) => i.kind === 'section' && i.id !== exclude)
    ?.id ?? null
}

export function movedBoard(
  board: Board,
  ids: readonly string[],
  dx: number,
  dy: number,
): Board {
  const moving = new Set(ids)
  return {
    ...board,
    items: board.items.map((item) =>
      moving.has(item.id) && !(item.parent !== null && moving.has(item.parent))
        ? { ...item, x: item.x + dx, y: item.y + dy }
        : item
    ),
  }
}

// `frame` in board points.
export function resizedBoard(board: Board, id: string, frame: Rect): Board {
  const item = board.items.find((i) => i.id === id)
  const parent = item?.parent == null
    ? undefined
    : board.items.find((i) => i.id === item.parent)
  const x = frame.x - (parent?.x ?? 0)
  const y = frame.y - (parent?.y ?? 0)
  return {
    ...board,
    items: board.items.map((i) =>
      i.id === id ? { ...i, x, y, w: frame.w, h: frame.h } : i
    ),
  }
}

export function offsetBoard(board: Board, id: string, offset: number): Board {
  return {
    ...board,
    connectors: board.connectors.map((c) => c.id === id ? { ...c, offset } : c),
  }
}

// The opposite corner stays put; neither side shrinks under the minimum.
export function resizedFrame(
  start: Rect,
  corner: Corner,
  dx: number,
  dy: number,
): Rect {
  const min = chrome.minimumSize
  let left = start.x
  let top = start.y
  let right = start.x + start.w
  let bottom = start.y + start.h
  if (corner === 'topLeft' || corner === 'bottomLeft') {
    left = Math.min(left + dx, right - min)
  } else right = Math.max(right + dx, left + min)
  if (corner === 'topLeft' || corner === 'topRight') {
    top = Math.min(top + dy, bottom - min)
  } else bottom = Math.max(bottom + dy, top + min)
  return { x: left, y: top, w: right - left, h: bottom - top }
}

const clamp = (value: number, low: number, high: number) =>
  Math.max(low, Math.min(high, value))

// The contextual bar's top-left in view points: centred above the
// selection, below it when there is no room, kept inside the view.
export function barOrigin(
  selection: Rect,
  bar: { w: number; h: number },
  view: { w: number; h: number },
  margin = 8,
): Point {
  const gap = chrome.sideOffset + margin
  let y = selection.y - gap - bar.h
  if (y < margin) y = selection.y + selection.h + gap
  return {
    x: clamp(
      selection.x + selection.w / 2 - bar.w / 2,
      margin,
      Math.max(margin, view.w - chrome.toolStripClearance - bar.w - margin),
    ),
    y: clamp(y, margin, view.h - bar.h - margin),
  }
}
