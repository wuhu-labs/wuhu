import type { Point } from './scene.ts'

export interface PointerSinks {
  // Whether the editing input takes this lone pointer.
  claim(at: Point): boolean
  edit(at: Point): void
  release(at: Point, cancelled: boolean): void
  pan(dx: number, dy: number): void
  pinch(mid: Point, dx: number, dy: number, ratio: number): void
}

// Routes the board's pointers: one claimed pointer edits; otherwise one drags
// the board and two pinch it about their midpoint. A second finger landing
// during an edit cancels it and joins the pinch, so zoom still wins.
export class PointerRouter {
  #free = new Map<number, Point>()
  #claimed: { id: number; at: Point } | null = null

  constructor(private readonly sinks: PointerSinks) {}

  get pinching(): boolean {
    return this.#free.size === 2
  }

  // Whether the pointer is now followed.
  down(id: number, at: Point): boolean {
    const claimed = this.#claimed
    if (claimed !== null) {
      this.#claimed = null
      this.sinks.release(claimed.at, true)
      this.#free.set(claimed.id, claimed.at)
    } else if (this.#free.size === 0 && this.sinks.claim(at)) {
      this.#claimed = { id, at }
      return true
    }
    if (this.#free.size >= 2) return false
    this.#free.set(id, at)
    return true
  }

  move(id: number, at: Point) {
    const claimed = this.#claimed
    if (claimed?.id === id) {
      claimed.at = at
      this.sinks.edit(at)
      return
    }
    const last = this.#free.get(id)
    if (last === undefined) return
    const before = this.#spread()
    this.#free.set(id, at)
    if (before === null) {
      this.sinks.pan(at.x - last.x, at.y - last.y)
      return
    }
    const after = this.#spread()!
    this.sinks.pinch(
      after.mid,
      after.mid.x - before.mid.x,
      after.mid.y - before.mid.y,
      before.distance === 0 ? 1 : after.distance / before.distance,
    )
  }

  up(id: number, at: Point, cancelled: boolean) {
    if (this.#claimed?.id === id) {
      this.#claimed = null
      this.sinks.release(at, cancelled)
      return
    }
    this.#free.delete(id)
  }

  #spread() {
    if (this.#free.size !== 2) return null
    const [a, b] = [...this.#free.values()]
    return {
      mid: { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 },
      distance: Math.hypot(a.x - b.x, a.y - b.y),
    }
  }
}
