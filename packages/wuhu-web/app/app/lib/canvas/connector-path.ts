import type { Point, SceneConnector } from './scene.ts'

// How a connector draws, as native's SceneBoard draws it: a round-capped
// line whose bends are arcs, and open chevron heads stroked with it whose
// tips stop half a line short of the ends. Board points.

export const arrowHead = { length: 7.5, width: 12.25 }
export const bendRadius = 20
// A right-angle quarter circle as one cubic.
const kappa = 0.5523

const at = (p: Point) => `${p.x},${p.y}`

export function connectorPaths(
  connector: Pick<SceneConnector, 'points' | 'arrow' | 'stroke'>,
): { line: string; heads: string } {
  const points = [...connector.points]
  const width = connector.stroke.width
  let heads = ''
  const head = (tip: Point, tail: Point): Point => {
    const dx = tip.x - tail.x
    const dy = tip.y - tail.y
    const length = Math.max(Math.hypot(dx, dy), 1e-6)
    const ux = dx / length
    const uy = dy / length
    const pulled = { x: tip.x - ux * width / 2, y: tip.y - uy * width / 2 }
    const base = {
      x: pulled.x - ux * arrowHead.length,
      y: pulled.y - uy * arrowHead.length,
    }
    const half = arrowHead.width / 2
    heads += `M${at({ x: base.x - uy * half, y: base.y + ux * half })}L${
      at(pulled)
    }L${at({ x: base.x + uy * half, y: base.y - ux * half })}`
    return pulled
  }
  const last = points.length - 1
  if (connector.arrow === 'end' || connector.arrow === 'both') {
    points[last] = head(points[last], points[last - 1])
  }
  if (connector.arrow === 'both') points[0] = head(points[0], points[1])
  return { line: rounded(points), heads }
}

// The polyline with each bend an arc of `bendRadius`, or less where a leg is
// too short for it.
export function rounded(points: readonly Point[]): string {
  let path = `M${at(points[0])}`
  for (let i = 1; i < points.length - 1; i++) {
    const before = points[i - 1]
    const corner = points[i]
    const after = points[i + 1]
    const inLength = Math.hypot(corner.x - before.x, corner.y - before.y)
    const outLength = Math.hypot(after.x - corner.x, after.y - corner.y)
    const radius = Math.min(
      bendRadius,
      inLength / (i > 1 ? 2 : 1),
      outLength / (i + 1 < points.length - 1 ? 2 : 1),
    )
    if (!(radius > 0 && inLength > 0 && outLength > 0)) {
      path += `L${at(corner)}`
      continue
    }
    const u = {
      x: (corner.x - before.x) / inLength,
      y: (corner.y - before.y) / inLength,
    }
    const v = {
      x: (after.x - corner.x) / outLength,
      y: (after.y - corner.y) / outLength,
    }
    const start = { x: corner.x - u.x * radius, y: corner.y - u.y * radius }
    const end = { x: corner.x + v.x * radius, y: corner.y + v.y * radius }
    const k = kappa * radius
    path += `L${at(start)}C${
      at({ x: start.x + u.x * k, y: start.y + u.y * k })
    } ${at({ x: end.x - v.x * k, y: end.y - v.y * k })} ${at(end)}`
  }
  return path + `L${at(points[points.length - 1])}`
}
