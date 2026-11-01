import type {
  Arrow,
  Board,
  BoardConnector,
  BoardItem,
  CanvasColor,
  ItemKind,
  Side,
  TextRun,
} from './board.ts'

// CanvasDocument's `CanvasScene` in TypeScript: what a renderer draws, all
// geometry absolute in board points and colours resolved to #RRGGBBAA. It
// mirrors the Swift `CanvasScene` rule for rule; the shared fixture
// (scene-cases.json) holds both to it.

export interface Point {
  x: number
  y: number
}

export interface Rect {
  x: number
  y: number
  w: number
  h: number
}

export type Shape =
  | { kind: 'roundedRect'; radius: number }
  | { kind: 'ellipse' }
  | { kind: 'diamond' }

export interface Stroke {
  color: string
  width: number
}

export type TextAlignment = 'topLeading' | 'center' | 'bottomLeading'

export interface SceneText {
  runs: TextRun[]
  box: Rect
  alignment: TextAlignment
  size: number
  // Text that does not fit shrinks down to `minSize`, then clips.
  shrink: boolean
}

export interface SceneItem {
  id: string
  kind: ItemKind
  frame: Rect
  shape: Shape
  fill?: string
  stroke?: Stroke
  text?: SceneText
  image?: { path: string }
}

export interface SceneConnector {
  id: string
  points: Point[]
  arrow: Arrow
  stroke: Stroke
  label?: { runs: TextRun[]; anchor: Point }
}

export interface CanvasScene {
  // Paint order: every section, then every other item.
  items: SceneItem[]
  connectors: SceneConnector[]
}

export const minTextSize = 8
export const textColor = '#1F2937FF'
export const labelColor = '#374151FF'
export const labelSize = 12
export const arrowHead = { length: 10, width: 8 }

const palette: Record<CanvasColor, { fill: string; stroke: string }> = {
  yellow: { fill: '#FFE48A', stroke: '#E5C04A' },
  pink: { fill: '#FFC4D8', stroke: '#E58FB0' },
  green: { fill: '#C2EBC8', stroke: '#78C589' },
  blue: { fill: '#C3DEFF', stroke: '#7BAEEC' },
  purple: { fill: '#DDCDFF', stroke: '#A68AE8' },
  gray: { fill: '#E8E8E8', stroke: '#B0B0B0' },
}

export const connectorStroke: Stroke = { color: '#6B7280FF', width: 2 }

export function swatchOf(color: CanvasColor): string {
  return palette[color].fill
}

function rgba(hex: string, alpha = 1): string {
  const byte = Math.round(alpha * 255).toString(16).toUpperCase()
  return hex + byte.padStart(2, '0')
}

const inset = (r: Rect, dx: number, dy = dx): Rect => ({
  x: r.x + dx,
  y: r.y + dy,
  w: r.w - 2 * dx,
  h: r.h - 2 * dy,
})

// Where an item's text sits and how it is set, even while it has none.
export function textLayoutOf(item: BoardItem, frame: Rect): SceneText {
  const runs = item.text.length === 0 ? [{ text: '' }] : item.text
  return sceneItem({ ...item, text: runs }, frame).text!
}

const imageExtensions = /\.(png|jpe?g|gif|webp|heic)$/i

function nameOf(path: string): string {
  return path.slice(path.lastIndexOf('/') + 1)
}

function sceneItem(item: BoardItem, frame: Rect): SceneItem {
  const text = (
    box: Rect,
    alignment: TextAlignment,
    size: number,
    shrink = true,
    runs = item.text,
  ): { text?: SceneText } =>
    runs.length === 0 ? {} : { text: { runs, box, alignment, size, shrink } }
  const shapeItem = (shape: Shape) => {
    const { fill, stroke } = palette[item.color ?? 'gray']
    return {
      shape,
      fill: rgba(fill),
      stroke: { color: rgba(stroke), width: 1.5 },
      ...text(
        shape.kind === 'diamond'
          ? inset(frame, frame.w / 4, frame.h / 4)
          : inset(frame, 12),
        'center',
        14,
      ),
    }
  }
  const base = { id: item.id, kind: item.kind, frame }
  switch (item.kind) {
    case 'sticky':
      return {
        ...base,
        shape: { kind: 'roundedRect', radius: 4 },
        fill: rgba(palette[item.color ?? 'yellow'].fill),
        ...text(inset(frame, 12), 'topLeading', 16),
      }
    case 'text':
      return {
        ...base,
        shape: { kind: 'roundedRect', radius: 0 },
        ...text(inset(frame, 4), 'topLeading', 16),
      }
    case 'rect':
      return { ...base, ...shapeItem({ kind: 'roundedRect', radius: 8 }) }
    case 'ellipse':
      return { ...base, ...shapeItem({ kind: 'ellipse' }) }
    case 'diamond':
      return { ...base, ...shapeItem({ kind: 'diamond' }) }
    case 'section': {
      const { fill, stroke } = palette[item.color ?? 'gray']
      return {
        ...base,
        shape: { kind: 'roundedRect', radius: 12 },
        fill: rgba(fill, 0.35),
        stroke: { color: rgba(stroke), width: 1 },
        ...text(
          { x: frame.x + 12, y: frame.y + 8, w: frame.w - 24, h: 20 },
          'topLeading',
          13,
          false,
        ),
      }
    }
    case 'file': {
      const path = item.path ?? ''
      return {
        ...base,
        shape: { kind: 'roundedRect', radius: 10 },
        fill: '#FFFFFFFF',
        stroke: { color: '#D0D0D0FF', width: 1 },
        ...text(
          {
            x: frame.x + 10,
            y: frame.y + frame.h - 28,
            w: frame.w - 20,
            h: 28,
          },
          'bottomLeading',
          12,
          true,
          [{ text: nameOf(path) }],
        ),
        ...(imageExtensions.test(path) ? { image: { path } } : {}),
      }
    }
  }
}

const centre = (r: Rect): Point => ({ x: r.x + r.w / 2, y: r.y + r.h / 2 })

const horizontal = (side: Side) => side === 'left' || side === 'right'

// The side of `own` facing `other`, centre to centre; ties go horizontal.
export function facing(own: Rect, other: Rect): Side {
  const a = centre(own)
  const b = centre(other)
  const dx = b.x - a.x
  const dy = b.y - a.y
  if (Math.abs(dx) >= Math.abs(dy)) return dx >= 0 ? 'right' : 'left'
  return dy >= 0 ? 'bottom' : 'top'
}

export function anchor(r: Rect, side: Side): Point {
  switch (side) {
    case 'top':
      return { x: r.x + r.w / 2, y: r.y }
    case 'right':
      return { x: r.x + r.w, y: r.y + r.h / 2 }
    case 'bottom':
      return { x: r.x + r.w / 2, y: r.y + r.h }
    case 'left':
      return { x: r.x, y: r.y + r.h / 2 }
  }
}

// One pass against the kept points: a repeat of the last is dropped, and a
// kept point in line (same x or same y) with its neighbours goes.
function collapsed(points: Point[]): Point[] {
  const kept: Point[] = []
  for (const p of points) {
    const last = kept.at(-1)
    if (last !== undefined && last.x === p.x && last.y === p.y) continue
    const before = kept.at(-2)
    if (
      before !== undefined && last !== undefined &&
      ((before.x === last.x && last.x === p.x) ||
        (before.y === last.y && last.y === p.y))
    ) kept.pop()
    kept.push(p)
  }
  return kept.length === 1 ? [kept[0], kept[0]] : kept
}

export function route(
  connector: Pick<BoardConnector, 'fromSide' | 'toSide' | 'style' | 'offset'>,
  from: Rect,
  to: Rect,
): Point[] {
  const fromSide = connector.fromSide ?? facing(from, to)
  const toSide = connector.toSide ?? facing(to, from)
  const a = anchor(from, fromSide)
  const b = anchor(to, toSide)
  if (connector.style === 'straight') return [a, b]
  const offset = connector.offset
  if (horizontal(fromSide) && horizontal(toSide)) {
    const mx = (a.x + b.x) / 2 + offset
    return collapsed([a, { x: mx, y: a.y }, { x: mx, y: b.y }, b])
  }
  if (!horizontal(fromSide) && !horizontal(toSide)) {
    const my = (a.y + b.y) / 2 + offset
    return collapsed([a, { x: a.x, y: my }, { x: b.x, y: my }, b])
  }
  const corner = horizontal(fromSide) ? { x: b.x, y: a.y } : { x: a.x, y: b.y }
  return collapsed([a, corner, b])
}

export function midpoint(points: Point[]): Point {
  const lengths = points.slice(1).map((p, i) =>
    Math.hypot(p.x - points[i].x, p.y - points[i].y)
  )
  let rest = lengths.reduce((sum, length) => sum + length, 0) / 2
  for (const [i, length] of lengths.entries()) {
    if (rest <= length && length > 0) {
      const t = rest / length
      const p = points[i]
      const q = points[i + 1]
      return { x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t }
    }
    rest -= length
  }
  return points[0]
}

export function sceneOf(board: Board): CanvasScene {
  const frames = new Map<string, Rect>()
  const sections: SceneItem[] = []
  const others: SceneItem[] = []
  for (const item of board.items) {
    const origin = item.parent == null ? undefined : frames.get(item.parent)
    const frame = {
      x: item.x + (origin?.x ?? 0),
      y: item.y + (origin?.y ?? 0),
      w: item.w,
      h: item.h,
    }
    frames.set(item.id, frame)
    ;(item.kind === 'section' ? sections : others).push(sceneItem(item, frame))
  }
  const connectors: SceneConnector[] = []
  for (const connector of board.connectors) {
    const from = frames.get(connector.from)
    const to = frames.get(connector.to)
    if (from === undefined || to === undefined) continue
    if (connector.from === connector.to) continue
    const points = route(connector, from, to)
    const hasLabel = connector.label.some((run) => run.text !== '')
    connectors.push({
      id: connector.id,
      points,
      arrow: connector.arrow,
      stroke: connectorStroke,
      ...(hasLabel
        ? { label: { runs: connector.label, anchor: midpoint(points) } }
        : {}),
    })
  }
  return { items: [...sections, ...others], connectors }
}

export function boundsOf(rects: Iterable<Rect>): Rect | null {
  let minX = Infinity
  let minY = Infinity
  let maxX = -Infinity
  let maxY = -Infinity
  for (const r of rects) {
    minX = Math.min(minX, r.x)
    minY = Math.min(minY, r.y)
    maxX = Math.max(maxX, r.x + r.w)
    maxY = Math.max(maxY, r.y + r.h)
  }
  if (minX > maxX) return null
  return { x: minX, y: minY, w: maxX - minX, h: maxY - minY }
}

export function connectorBounds(connector: SceneConnector): Rect {
  const xs = connector.points.map((p) => p.x)
  const ys = connector.points.map((p) => p.y)
  const x = Math.min(...xs)
  const y = Math.min(...ys)
  return { x, y, w: Math.max(...xs) - x, h: Math.max(...ys) - y }
}
