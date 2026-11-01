import type { Rect } from './scene.ts'

// A uniform grid over board space: each rect is filed under every cell it
// touches, and a query answers the indices of the rects intersecting it, in
// ascending order (paint order when the rects are).
export class SpatialGrid {
  readonly #cells = new Map<string, number[]>()
  readonly #rects: readonly Rect[]
  readonly #cell: number

  constructor(rects: readonly Rect[], cell = 512) {
    this.#rects = rects
    this.#cell = cell
    rects.forEach((rect, index) => {
      this.#visit(rect, (key) => {
        const bucket = this.#cells.get(key)
        if (bucket === undefined) this.#cells.set(key, [index])
        else bucket.push(index)
      })
    })
  }

  query(area: Rect): number[] {
    const hits = new Set<number>()
    this.#visit(area, (key) => {
      for (const index of this.#cells.get(key) ?? []) {
        if (intersects(this.#rects[index], area)) hits.add(index)
      }
    })
    return [...hits].sort((a, b) => a - b)
  }

  #visit(rect: Rect, visit: (key: string) => void) {
    const x0 = Math.floor(rect.x / this.#cell)
    const y0 = Math.floor(rect.y / this.#cell)
    const x1 = Math.floor((rect.x + rect.w) / this.#cell)
    const y1 = Math.floor((rect.y + rect.h) / this.#cell)
    for (let x = x0; x <= x1; x++) {
      for (let y = y0; y <= y1; y++) visit(`${x},${y}`)
    }
  }
}

export function intersects(a: Rect, b: Rect): boolean {
  return a.x <= b.x + b.w && b.x <= a.x + a.w && a.y <= b.y + b.h &&
    b.y <= a.y + a.h
}

export function contains(outer: Rect, inner: Rect): boolean {
  return outer.x <= inner.x && outer.y <= inner.y &&
    inner.x + inner.w <= outer.x + outer.w &&
    inner.y + inner.h <= outer.y + outer.h
}

export function grown(r: Rect, fraction: number): Rect {
  const dx = r.w * fraction
  const dy = r.h * fraction
  return { x: r.x - dx, y: r.y - dy, w: r.w + 2 * dx, h: r.h + 2 * dy }
}
