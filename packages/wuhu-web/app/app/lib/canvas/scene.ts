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

const palette: Record<CanvasColor, { fill: string; stroke: string }> = {
  yellow: { fill: '#FFE48A', stroke: '#E5C04A' },
  pink: { fill: '#FFC4D8', stroke: '#E58FB0' },
  green: { fill: '#C2EBC8', stroke: '#78C589' },
  blue: { fill: '#B2D9FB', stroke: '#7BAEEC' },
  purple: { fill: '#DDCDFF', stroke: '#A68AE8' },
  gray: { fill: '#E8E8E8', stroke: '#B0B0B0' },
}

export const connectorStroke: Stroke = { color: '#D8DAE5FF', width: 3.2 }

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
        shape: { kind: 'roundedRect', radius: 0 },
        fill: rgba(palette[item.color ?? 'yellow'].fill),
        ...text(inset(frame, 20), 'topLeading', 16),
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

export interface End {
  point: Point
  side: Side
}

// Ends sharing a side stand `spreadGap` apart, spanning at most
// `spreadShare` of the side.
const spreadGap = 24
const spreadShare = 0.8

// The side facing `other` on the axis `first` does not use, when `other`'s
// centre lies past the frame on that axis.
function secondSide(frame: Rect, other: Rect, first: Side): Side | null {
  const o = centre(other)
  if (horizontal(first)) {
    return o.y > frame.y + frame.h ? 'bottom' : o.y < frame.y ? 'top' : null
  }
  return o.x > frame.x + frame.w ? 'right' : o.x < frame.x ? 'left' : null
}

// The point on the item's outline `offset` along `side` from its midpoint:
// an ellipse and a diamond curve and slope away from it.
export function outline(
  frame: Rect,
  kind: ItemKind | undefined,
  side: Side,
  offset: number,
): Point {
  const half = horizontal(side) ? frame.h / 2 : frame.w / 2
  const u = half > 0 ? Math.min(Math.abs(offset) / half, 1) : 0
  const depth = kind === 'diamond'
    ? u
    : kind === 'ellipse'
    ? 1 - Math.sqrt(1 - u * u)
    : 0
  const midX = frame.x + frame.w / 2
  const midY = frame.y + frame.h / 2
  switch (side) {
    case 'left':
      return { x: frame.x + frame.w / 2 * depth, y: midY + offset }
    case 'right':
      return { x: frame.x + frame.w - frame.w / 2 * depth, y: midY + offset }
    case 'top':
      return { x: midX + offset, y: frame.y + frame.h / 2 * depth }
    case 'bottom':
      return { x: midX + offset, y: frame.y + frame.h - frame.h / 2 * depth }
  }
}

// Where every drawable connector's ends sit, in board order. A free end
// takes the side facing the other item; when an end before it (pinned ends
// first) holds that side and the other item lies past the frame on the
// other axis, it takes the side facing it there instead. Ends still sharing
// a side spread along it, ordered by what they lead to, on the outline.
export function endsOf(
  connectors: readonly BoardConnector[],
  frames: ReadonlyMap<string, Rect>,
  kinds: ReadonlyMap<string, ItemKind>,
): [BoardConnector, End, End][] {
  const drawn = connectors.filter((c) =>
    c.from !== c.to && frames.has(c.from) && frames.has(c.to)
  )
  const slot = (item: string, side: Side) => `${item}|${side}`
  const taken = new Set<string>()
  for (const c of drawn) {
    if (c.fromSide !== undefined) taken.add(slot(c.from, c.fromSide))
    if (c.toSide !== undefined) taken.add(slot(c.to, c.toSide))
  }
  const free = (id: string, other: Rect): Side => {
    const frame = frames.get(id)!
    const first = facing(frame, other)
    if (!taken.has(slot(id, first))) return first
    const second = secondSide(frame, other, first)
    return second === null || taken.has(slot(id, second)) ? first : second
  }
  const sides = drawn.map((c): [Side, Side] => {
    const from = c.fromSide ?? free(c.from, frames.get(c.to)!)
    taken.add(slot(c.from, from))
    const to = c.toSide ?? free(c.to, frames.get(c.from)!)
    taken.add(slot(c.to, to))
    return [from, to]
  })
  const sharing = new Map<
    string,
    {
      item: string
      side: Side
      members: { index: number; from: boolean; toward: Point }[]
    }
  >()
  const share = (
    item: string,
    side: Side,
    member: { index: number; from: boolean; toward: Point },
  ) => {
    const key = slot(item, side)
    const entry = sharing.get(key) ?? { item, side, members: [] }
    entry.members.push(member)
    sharing.set(key, entry)
  }
  drawn.forEach((c, index) => {
    share(c.from, sides[index][0], {
      index,
      from: true,
      toward: centre(frames.get(c.to)!),
    })
    share(c.to, sides[index][1], {
      index,
      from: false,
      toward: centre(frames.get(c.from)!),
    })
  })
  const ends = drawn.map((c, index): [End, End] => [
    {
      point: anchor(frames.get(c.from)!, sides[index][0]),
      side: sides[index][0],
    },
    {
      point: anchor(frames.get(c.to)!, sides[index][1]),
      side: sides[index][1],
    },
  ])
  for (const { item, side, members } of sharing.values()) {
    if (members.length < 2) continue
    const frame = frames.get(item)!
    const length = horizontal(side) ? frame.h : frame.w
    const spacing = Math.min(
      spreadGap,
      length * spreadShare / (members.length - 1),
    )
    const along = (p: Point) => horizontal(side) ? p.y : p.x
    const ordered = [...members].sort((a, b) =>
      along(a.toward) - along(b.toward)
    )
    ordered.forEach((member, rank) => {
      const offset = (rank - (members.length - 1) / 2) * spacing
      ends[member.index][member.from ? 0 : 1].point = outline(
        frame,
        kinds.get(item),
        side,
        offset,
      )
    })
  }
  return drawn.map((c, index) => [c, ...ends[index]])
}

export function route(
  connector: Pick<BoardConnector, 'style' | 'offset'>,
  from: End,
  to: End,
): Point[] {
  const fromSide = from.side
  const toSide = to.side
  const a = from.point
  const b = to.point
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
  const kinds = new Map<string, ItemKind>()
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
    if (!kinds.has(item.id)) kinds.set(item.id, item.kind)
    ;(item.kind === 'section' ? sections : others).push(sceneItem(item, frame))
  }
  const connectors = endsOf(board.connectors, frames, kinds).map(
    ([connector, from, to]): SceneConnector => {
      const points = route(connector, from, to)
      const hasLabel = connector.label.some((run) => run.text !== '')
      return {
        id: connector.id,
        points,
        arrow: connector.arrow,
        stroke: connectorStroke,
        ...(hasLabel
          ? { label: { runs: connector.label, anchor: midpoint(points) } }
          : {}),
      }
    },
  )
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
