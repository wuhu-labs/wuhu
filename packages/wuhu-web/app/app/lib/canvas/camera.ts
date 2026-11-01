import type { Point, Rect } from './scene.ts'

// The board point at the view's top-left, and how many view pixels a board
// point spans: view = (board − camera) × scale.
export interface Camera {
  x: number
  y: number
  scale: number
}

export const minScale = 0.1
export const maxScale = 8

const clamp = (value: number, low: number, high: number) =>
  Math.min(high, Math.max(low, value))

export function toBoard(camera: Camera, view: Point): Point {
  return {
    x: camera.x + view.x / camera.scale,
    y: camera.y + view.y / camera.scale,
  }
}

// Zooms by `factor`, keeping the board point under `view` where it is.
export function zoomedAt(camera: Camera, view: Point, factor: number): Camera {
  const scale = clamp(camera.scale * factor, minScale, maxScale)
  const pinned = toBoard(camera, view)
  return { x: pinned.x - view.x / scale, y: pinned.y - view.y / scale, scale }
}

// Moves the board with the pointer by (dx, dy) view pixels.
export function dragged(camera: Camera, dx: number, dy: number): Camera {
  return {
    x: camera.x - dx / camera.scale,
    y: camera.y - dy / camera.scale,
    scale: camera.scale,
  }
}

export function visibleRect(
  camera: Camera,
  viewport: { w: number; h: number },
): Rect {
  return {
    x: camera.x,
    y: camera.y,
    w: viewport.w / camera.scale,
    h: viewport.h / camera.scale,
  }
}

// The whole of `bounds` centred in the view, never past 100%.
export function fitted(
  bounds: Rect,
  viewport: { w: number; h: number },
  margin = 48,
): Camera {
  const scale = clamp(
    Math.min(
      (viewport.w - 2 * margin) / Math.max(bounds.w, 1),
      (viewport.h - 2 * margin) / Math.max(bounds.h, 1),
      1,
    ),
    minScale,
    maxScale,
  )
  return {
    x: bounds.x + bounds.w / 2 - viewport.w / 2 / scale,
    y: bounds.y + bounds.h / 2 - viewport.h / 2 / scale,
    scale,
  }
}

export interface Wheel {
  deltaX: number
  deltaY: number
  // WheelEvent.deltaMode: pixels, lines or pages.
  deltaMode: number
  ctrlKey: boolean
  metaKey: boolean
}

const lineHeight = 16
const zoomPerPixel = 0.01
// One notch of a mouse wheel is ~100 px; a step past this would jump.
const maxZoomStep = 50

// A plain wheel or two-finger scroll pans; ctrl (a trackpad pinch arrives as
// ctrl-wheel) or ⌘ zooms at the pointer.
export function wheeled(
  camera: Camera,
  wheel: Wheel,
  view: Point,
  viewport: { w: number; h: number },
): Camera {
  const unit = wheel.deltaMode === 1
    ? lineHeight
    : wheel.deltaMode === 2
    ? viewport.h
    : 1
  const dx = wheel.deltaX * unit
  const dy = wheel.deltaY * unit
  if (wheel.ctrlKey || wheel.metaKey) {
    const step = clamp(dy, -maxZoomStep, maxZoomStep)
    return zoomedAt(camera, view, Math.exp(-step * zoomPerPixel))
  }
  return dragged(camera, -dx, -dy)
}

// ⌘+ / ⌘− step by this factor about the view's centre.
export const keyZoomStep = 1.25
