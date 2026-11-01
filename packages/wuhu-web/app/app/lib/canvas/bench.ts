import { type Camera, maxScale, minScale, zoomedAt } from './camera.ts'
import type { Point } from './scene.ts'

// The canvas lab's scripted run: phases of one camera per frame, the same
// on every browser, and the frame-interval statistics measured over them.

export interface Phase {
  name: string
  cameras: Camera[]
}

function zoomSweep(
  name: string,
  start: Camera,
  at: Point,
  to: number,
  frames: number,
): Phase {
  const step = Math.pow(to / start.scale, 1 / frames)
  const cameras: Camera[] = []
  let camera = start
  for (let i = 0; i < frames; i++) {
    camera = zoomedAt(camera, at, step)
    cameras.push(camera)
  }
  return { name, cameras }
}

function panSweep(
  name: string,
  start: Camera,
  { dx, dy }: { dx: number; dy: number },
  frames: number,
): Phase {
  const cameras: Camera[] = []
  for (let i = 1; i <= frames; i++) {
    cameras.push({
      x: start.x + (dx * i) / frames / start.scale,
      y: start.y + (dy * i) / frames / start.scale,
      scale: start.scale,
    })
  }
  return { name, cameras }
}

// Zoom in from 10% to 800% at a point, pan at 800%, zoom back out, then pan
// at 100% and at 10%: four seconds of each at 60 fps.
export function benchPhases(
  centre: Point,
  viewport: { w: number; h: number },
  board: Point,
): Phase[] {
  const far: Camera = {
    x: board.x - centre.x / minScale,
    y: board.y - centre.y / minScale,
    scale: minScale,
  }
  const zoomIn = zoomSweep('zoom 10%→800%', far, centre, maxScale, 240)
  const near = zoomIn.cameras.at(-1)!
  const panNear = panSweep('pan 800%', near, { dx: viewport.w, dy: 0 }, 120)
  const zoomOut = zoomSweep(
    'zoom 800%→10%',
    panNear.cameras.at(-1)!,
    centre,
    minScale,
    240,
  )
  const mid = zoomSweep('to 100%', zoomOut.cameras.at(-1)!, centre, 1, 1)
  const panMid = panSweep(
    'pan 100%',
    mid.cameras[0],
    { dx: 3 * viewport.w, dy: viewport.h },
    240,
  )
  const panFar = panSweep(
    'pan 10%',
    far,
    { dx: viewport.w / 2, dy: viewport.h / 4 },
    120,
  )
  return [zoomIn, panNear, zoomOut, panMid, panFar]
}

export interface FrameStats {
  name: string
  frames: number
  mean: number
  p50: number
  p95: number
  p99: number
  max: number
  // Intervals over 1.5× the display's idle frame: visibly dropped frames.
  dropped: number
}

const round = (value: number) => Math.round(value * 100) / 100

export function frameStats(
  name: string,
  intervals: number[],
  refresh: number,
): FrameStats {
  const sorted = [...intervals].sort((a, b) => a - b)
  const at = (q: number) =>
    sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))] ?? 0
  const mean = sorted.reduce((sum, value) => sum + value, 0) /
    Math.max(sorted.length, 1)
  return {
    name,
    frames: sorted.length,
    mean: round(mean),
    p50: round(at(0.5)),
    p95: round(at(0.95)),
    p99: round(at(0.99)),
    max: round(sorted.at(-1) ?? 0),
    dropped: sorted.filter((value) => value > 1.5 * refresh).length,
  }
}
