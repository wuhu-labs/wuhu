import {
  dragged,
  fitted,
  maxScale,
  minScale,
  wheeled,
  zoomedAt,
} from './camera.ts'
import { SpatialGrid } from './grid.ts'

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

const viewport = { w: 1000, h: 800 }
const wheel = {
  deltaX: 0,
  deltaY: 0,
  deltaMode: 0,
  ctrlKey: false,
  metaKey: false,
}

Deno.test('zoom keeps the board point under the pointer', () => {
  const camera = { x: 100, y: 50, scale: 1 }
  const at = { x: 300, y: 200 }
  const zoomed = zoomedAt(camera, at, 2)
  assertEquals(zoomed, { x: 250, y: 150, scale: 2 })
  // Board point (400, 250) was under the pointer and still is.
  assertEquals(zoomed.x + at.x / zoomed.scale, 400)
  assertEquals(zoomed.y + at.y / zoomed.scale, 250)
})

Deno.test('zoom clamps to 10%–800%, still anchored', () => {
  const camera = { x: 0, y: 0, scale: 1 }
  assertEquals(zoomedAt(camera, { x: 0, y: 0 }, 100).scale, maxScale)
  assertEquals(zoomedAt(camera, { x: 0, y: 0 }, 0.001).scale, minScale)
  const out = zoomedAt(camera, { x: 500, y: 400 }, 0.001)
  assertEquals(out, { x: -4500, y: -3600, scale: minScale })
})

Deno.test('a plain wheel pans in board units; ctrl or ⌘ zooms', () => {
  const camera = { x: 0, y: 0, scale: 2 }
  const at = { x: 500, y: 400 }
  assertEquals(
    wheeled(camera, { ...wheel, deltaX: 20, deltaY: 40 }, at, viewport),
    { x: 10, y: 20, scale: 2 },
  )
  assertEquals(
    wheeled(camera, { ...wheel, deltaY: 3, deltaMode: 1 }, at, viewport),
    { x: 0, y: 24, scale: 2 },
  )
  const pinch = wheeled(
    camera,
    { ...wheel, deltaY: -10, ctrlKey: true },
    at,
    viewport,
  )
  assertEquals(pinch.scale, 2 * Math.exp(0.1))
  const notch = wheeled(
    camera,
    { ...wheel, deltaY: 400, metaKey: true },
    at,
    viewport,
  )
  assertEquals(notch.scale, 2 * Math.exp(-0.5))
})

Deno.test('drag moves the board with the pointer', () => {
  assertEquals(dragged({ x: 0, y: 0, scale: 4 }, 40, -8), {
    x: -10,
    y: 2,
    scale: 4,
  })
})

Deno.test('fit centres the board, never past 100%', () => {
  assertEquals(fitted({ x: 0, y: 0, w: 100, h: 100 }, viewport), {
    x: -450,
    y: -350,
    scale: 1,
  })
  const big = fitted({ x: 0, y: 0, w: 9040, h: 7040 }, viewport)
  assertEquals(big.scale, 0.1)
})

Deno.test('the grid answers intersecting rects in index order', () => {
  const grid = new SpatialGrid([
    { x: 0, y: 0, w: 10, h: 10 },
    { x: 2000, y: 2000, w: 10, h: 10 },
    { x: -600, y: -600, w: 1300, h: 1300 },
    { x: 400, y: 400, w: 10, h: 10 },
  ])
  assertEquals(grid.query({ x: 0, y: 0, w: 500, h: 500 }), [0, 2, 3])
  assertEquals(grid.query({ x: 1990, y: 1990, w: 5, h: 5 }), [])
  assertEquals(grid.query({ x: 1990, y: 1990, w: 10, h: 10 }), [1])
})
