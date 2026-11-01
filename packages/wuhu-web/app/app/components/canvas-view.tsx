import {
  type CSSProperties,
  memo,
  type ReactNode,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from 'react'
import {
  type Camera,
  dragged,
  fitted,
  keyZoomStep,
  toBoard,
  visibleRect,
  wheeled,
  zoomedAt,
} from '~/lib/canvas/camera'
import { contains, grown, SpatialGrid } from '~/lib/canvas/grid'
import { PointerRouter } from '~/lib/canvas/pointers'
import type { TextRun } from '~/lib/canvas/board'
import {
  arrowHead,
  boundsOf,
  type CanvasScene,
  connectorBounds,
  connectorStroke,
  labelColor,
  labelSize,
  minTextSize,
  type Point,
  type SceneConnector,
  type SceneItem,
  type SceneText,
  textColor,
} from '~/lib/canvas/scene'

// Draws a CanvasScene: absolutely positioned DOM items and one SVG layer of
// connectors in a world div, moved by a CSS transform. The transform is
// never pinned with will-change, so the browser re-rasters text at every
// scale instead of stretching a bitmap. Only what the view (plus a margin)
// shows is mounted.

export interface CanvasViewProps {
  scene: CanvasScene
  // The URL of an image at a space path, or null when there is none.
  imageSrc(path: string): string | null
  crossOrigin?: 'use-credentials'
  // Called once per drawn frame with the camera it drew.
  onFrame?(camera: Camera): void
  initialCamera?: Camera
  // Set while mounted: the camera, and a jump that draws it at once.
  control?: { current: CanvasControl | null }
  // Editing: pointers it claims edit instead of panning.
  input?: CanvasInput
  // The item whose text an editor draws instead.
  editingText?: string | null
  // Screen-space chrome; pointers on it neither pan nor edit.
  children?: ReactNode
}

export interface CanvasInput {
  down(event: PointerEvent, at: Point, camera: Camera): boolean
  move(event: PointerEvent, at: Point, camera: Camera): void
  up(event: PointerEvent, at: Point, camera: Camera, cancelled: boolean): void
  doubleClick(at: Point, camera: Camera): void
  // Runs before the zoom keys; preventDefault keeps them out.
  key(event: KeyboardEvent): void
}

export interface CanvasControl {
  camera(): Camera
  jump(camera: Camera): void
  mountedItems(): number
}

interface Mounted {
  items: number[]
  connectors: number[]
}

const cullMargin = 0.5
// Zooming in leaves the mounted set alone until it is this many times the
// area on screen and the camera has rested.
const shrinkRatio = 9
const restMs = 150
// The connector's bounds grow by this much so a label off its line stays.
const labelSlack = 80

function dotSpacing(scale: number): number {
  let spacing = 24
  while (spacing * scale < 12) spacing *= 4
  return spacing
}

export function CanvasView({
  scene,
  imageSrc,
  crossOrigin,
  onFrame,
  initialCamera,
  control,
  input,
  editingText = null,
  children,
}: CanvasViewProps) {
  const viewportRef = useRef<HTMLDivElement>(null)
  const worldRef = useRef<HTMLDivElement>(null)
  const zoomRef = useRef<HTMLSpanElement>(null)
  const markerId = useId()
  const [mounted, setMounted] = useState<Mounted>({
    items: [],
    connectors: [],
  })
  const grids = useMemo(() => ({
    items: new SpatialGrid(scene.items.map((item) => item.frame)),
    connectors: new SpatialGrid(
      scene.connectors.map((connector) => {
        const r = connectorBounds(connector)
        return {
          x: r.x - labelSlack,
          y: r.y - labelSlack,
          w: r.w + 2 * labelSlack,
          h: r.h + 2 * labelSlack,
        }
      }),
    ),
  }), [scene])

  const controller = useRef<{
    camera: Camera | null
    cull: ReturnType<typeof visibleRect> | null
    frame: number | null
    rest: ReturnType<typeof setTimeout> | null
    grids: typeof grids
    draw: (() => void) | null
  }>({ camera: null, cull: null, frame: null, rest: null, grids, draw: null })
  // The listeners outlive renders; they read the latest props here.
  const latest = useRef({ scene, onFrame, initialCamera, control, input })
  latest.current = { scene, onFrame, initialCamera, control, input }

  useLayoutEffect(() => {
    const state = controller.current
    state.grids = grids
    state.cull = null
    state.draw?.()
  }, [grids])

  useLayoutEffect(() => {
    const viewport = viewportRef.current!
    const world = worldRef.current!
    const state = controller.current
    const { scene, initialCamera, control } = latest.current
    const size = () => ({ w: viewport.clientWidth, h: viewport.clientHeight })

    const remount = (camera: Camera) => {
      const cull = grown(visibleRect(camera, size()), cullMargin)
      state.cull = cull
      setMounted({
        items: state.grids.items.query(cull),
        connectors: state.grids.connectors.query(cull),
      })
    }
    const draw = () => {
      state.frame = null
      const camera = state.camera!
      const { x, y, scale } = camera
      world.style.transform = `scale(${scale}) translate(${-x}px, ${-y}px)`
      const spacing = dotSpacing(scale) * scale
      viewport.style.backgroundSize = `${spacing}px ${spacing}px`
      viewport.style.backgroundPosition = `${-x * scale}px ${-y * scale}px`
      if (zoomRef.current) {
        zoomRef.current.textContent = `${Math.round(scale * 100)}%`
      }
      const visible = visibleRect(camera, size())
      if (state.cull === null || !contains(state.cull, visible)) {
        remount(camera)
      }
      if (state.rest !== null) clearTimeout(state.rest)
      state.rest = setTimeout(() => {
        state.rest = null
        const cull = state.cull
        if (
          cull !== null &&
          cull.w * cull.h > shrinkRatio * visible.w * visible.h
        ) remount(state.camera!)
      }, restMs)
      latest.current.onFrame?.(camera)
    }
    state.draw = () => {
      if (state.frame !== null) cancelAnimationFrame(state.frame)
      draw()
    }
    const move = (camera: Camera) => {
      state.camera = camera
      state.frame ??= requestAnimationFrame(draw)
    }

    if (state.camera === null) {
      const bounds = boundsOf(scene.items.map((item) => item.frame))
      state.camera = initialCamera ??
        (bounds === null ? { x: 0, y: 0, scale: 1 } : fitted(bounds, size()))
    }
    draw()
    if (control) {
      control.current = {
        camera: () => state.camera!,
        jump: (camera) => {
          state.camera = camera
          if (state.frame !== null) cancelAnimationFrame(state.frame)
          draw()
        },
        mountedItems: () =>
          world.querySelectorAll(':scope > .canvas-item').length,
      }
    }

    const pointerAt = (event: { clientX: number; clientY: number }): Point => {
      const box = viewport.getBoundingClientRect()
      return { x: event.clientX - box.left, y: event.clientY - box.top }
    }
    const wheel = (event: WheelEvent) => {
      event.preventDefault()
      move(wheeled(state.camera!, event, pointerAt(event), size()))
    }

    const onChrome = (event: Event) =>
      (event.target as Element).closest('.canvas-chrome') !== null
    const boardAt = (at: Point) => toBoard(state.camera!, at)
    let current: PointerEvent | null = null
    const router = new PointerRouter({
      claim: (at) => {
        const claimed =
          latest.current.input?.down(current!, boardAt(at), state.camera!) ===
            true
        if (claimed) viewport.focus({ preventScroll: true })
        return claimed
      },
      edit: (at) =>
        latest.current.input?.move(current!, boardAt(at), state.camera!),
      release: (at, cancelled) =>
        latest.current.input?.up(
          current!,
          boardAt(at),
          state.camera!,
          cancelled,
        ),
      pan: (dx, dy) => move(dragged(state.camera!, dx, dy)),
      pinch: (mid, dx, dy, ratio) =>
        move(zoomedAt(dragged(state.camera!, dx, dy), mid, ratio)),
    })
    const routed = (event: PointerEvent, route: (at: Point) => void) => {
      current = event
      try {
        route(pointerAt(event))
      } finally {
        current = null
      }
    }
    const down = (event: PointerEvent) => {
      if (event.button !== 0 || onChrome(event)) return
      if (
        latest.current.input === undefined &&
        (event.target as Element).closest('a')
      ) return
      routed(event, (at) => {
        if (router.down(event.pointerId, at)) {
          viewport.setPointerCapture(event.pointerId)
        }
      })
    }
    const moved = (event: PointerEvent) =>
      routed(event, (at) => router.move(event.pointerId, at))
    const up = (event: PointerEvent) =>
      routed(
        event,
        (at) => router.up(event.pointerId, at, event.type === 'pointercancel'),
      )
    const doubleClick = (event: MouseEvent) => {
      if (onChrome(event)) return
      latest.current.input?.doubleClick(
        boardAt(pointerAt(event)),
        state.camera!,
      )
    }

    // Safari's trackpad pinch: non-standard gesture events with a running
    // scale; a touch pinch is already handled by the pointers.
    let gestureScale = 1
    const gesture = (event: Event) => {
      event.preventDefault()
      const { scale, clientX, clientY } = event as Event & {
        scale: number
        clientX: number
        clientY: number
      }
      if (event.type === 'gesturestart') gestureScale = 1
      if (router.pinching || event.type !== 'gesturechange') return
      move(
        zoomedAt(
          state.camera!,
          pointerAt({ clientX, clientY }),
          scale / gestureScale,
        ),
      )
      gestureScale = scale
    }

    const key = (event: KeyboardEvent) => {
      if (onChrome(event)) return
      latest.current.input?.key(event)
      if (event.defaultPrevented) return
      if (!(event.metaKey || event.ctrlKey)) return
      const centre = { x: size().w / 2, y: size().h / 2 }
      const camera = state.camera!
      const factor = event.key === '=' || event.key === '+'
        ? keyZoomStep
        : event.key === '-'
        ? 1 / keyZoomStep
        : event.key === '0'
        ? 1 / camera.scale
        : null
      if (factor === null) return
      event.preventDefault()
      move(zoomedAt(camera, centre, factor))
    }

    const resized = new ResizeObserver(() => move(state.camera!))
    resized.observe(viewport)
    viewport.addEventListener('wheel', wheel, { passive: false })
    viewport.addEventListener('pointerdown', down)
    viewport.addEventListener('pointermove', moved)
    viewport.addEventListener('pointerup', up)
    viewport.addEventListener('pointercancel', up)
    viewport.addEventListener('keydown', key)
    viewport.addEventListener('dblclick', doubleClick)
    for (const type of ['gesturestart', 'gesturechange', 'gestureend']) {
      viewport.addEventListener(type, gesture)
    }
    return () => {
      resized.disconnect()
      viewport.removeEventListener('wheel', wheel)
      viewport.removeEventListener('pointerdown', down)
      viewport.removeEventListener('pointermove', moved)
      viewport.removeEventListener('pointerup', up)
      viewport.removeEventListener('pointercancel', up)
      viewport.removeEventListener('keydown', key)
      viewport.removeEventListener('dblclick', doubleClick)
      for (const type of ['gesturestart', 'gesturechange', 'gestureend']) {
        viewport.removeEventListener(type, gesture)
      }
      if (state.frame !== null) cancelAnimationFrame(state.frame)
      if (state.rest !== null) clearTimeout(state.rest)
      if (control) control.current = null
      state.frame = null
      state.rest = null
      state.draw = null
    }
  }, [])

  const connectors = mounted.connectors.map((i) => scene.connectors[i])
    .filter((c) => c !== undefined)
  return (
    <div
      ref={viewportRef}
      className='canvas-viewport'
      tabIndex={0}
      aria-label='Canvas'
    >
      <div ref={worldRef} className='canvas-world'>
        {mounted.items.map((i) => scene.items[i]).filter((item) =>
          item !== undefined
        ).map((item) => (
          <ItemView
            key={item.id}
            item={item}
            hideText={item.id === editingText}
            imageSrc={item.image ? imageSrc(item.image.path) : null}
            crossOrigin={crossOrigin}
          />
        ))}
        <svg className='canvas-connectors' width='1' height='1'>
          <defs>
            <marker
              id={markerId}
              markerUnits='userSpaceOnUse'
              markerWidth={arrowHead.length}
              markerHeight={arrowHead.width}
              refX={arrowHead.length}
              refY={arrowHead.width / 2}
              orient='auto-start-reverse'
            >
              <path
                d={`M0,0 L${arrowHead.length},${
                  arrowHead.width / 2
                } L0,${arrowHead.width} z`}
                fill={connectorStroke.color}
              />
            </marker>
          </defs>
          {connectors.map((connector) => (
            <ConnectorPath
              key={connector.id}
              connector={connector}
              marker={`url(#${CSS.escape(markerId)})`}
            />
          ))}
        </svg>
        {connectors.map((connector) =>
          connector.label && (
            <div
              key={connector.id}
              className='canvas-label'
              style={{
                left: connector.label.anchor.x,
                top: connector.label.anchor.y,
                color: labelColor,
                fontSize: labelSize,
              }}
            >
              <Runs runs={connector.label.runs} />
            </div>
          )
        )}
      </div>
      <span ref={zoomRef} className='canvas-zoom' aria-live='off' />
      {children}
    </div>
  )
}

const ConnectorPath = memo(function ConnectorPath({ connector, marker }: {
  connector: SceneConnector
  marker: string
}) {
  return (
    <polyline
      points={connector.points.map((p) => `${p.x},${p.y}`).join(' ')}
      stroke={connector.stroke.color}
      strokeWidth={connector.stroke.width}
      color={connector.stroke.color}
      markerEnd={connector.arrow === 'none' ? undefined : marker}
      markerStart={connector.arrow === 'both' ? marker : undefined}
    />
  )
})

const ItemView = memo(function ItemView({
  item,
  hideText,
  imageSrc,
  crossOrigin,
}: {
  item: SceneItem
  hideText: boolean
  imageSrc: string | null
  crossOrigin?: 'use-credentials'
}) {
  const { frame, shape, fill, stroke } = item
  const style: CSSProperties = {
    left: frame.x,
    top: frame.y,
    width: frame.w,
    height: frame.h,
  }
  if (shape.kind !== 'diamond') {
    style.background = fill
    style.borderRadius = shape.kind === 'ellipse' ? '50%' : shape.radius
    if (stroke) style.border = `${stroke.width}px solid ${stroke.color}`
  }
  return (
    <div className='canvas-item' data-kind={item.kind} style={style}>
      {shape.kind === 'diamond' && (
        <svg
          className='canvas-diamond'
          width={frame.w}
          height={frame.h}
          viewBox={`0 0 ${frame.w} ${frame.h}`}
        >
          <polygon
            points={`${frame.w / 2},${(stroke?.width ?? 0) / 2} ${
              frame.w - (stroke?.width ?? 0) / 2
            },${frame.h / 2} ${frame.w / 2},${
              frame.h - (stroke?.width ?? 0) / 2
            } ${(stroke?.width ?? 0) / 2},${frame.h / 2}`}
            fill={fill ?? 'none'}
            stroke={stroke?.color}
            strokeWidth={stroke?.width}
          />
        </svg>
      )}
      {imageSrc != null && (
        <img
          className='canvas-image'
          src={imageSrc}
          crossOrigin={crossOrigin}
          alt=''
          loading='lazy'
          decoding='async'
          draggable={false}
          style={{
            borderRadius: shape.kind === 'roundedRect' ? shape.radius : 0,
          }}
        />
      )}
      {item.text && !hideText && (
        <FittedText
          text={item.text}
          origin={{ x: frame.x, y: frame.y }}
          strokeInset={shape.kind === 'diamond' ? 0 : stroke?.width ?? 0}
        />
      )}
    </div>
  )
})

// Fitted sizes outlive a remount, so panning back does not measure again.
const fittedSizes = new Map<string, number>()

function fitKey(text: SceneText): string {
  return `${text.size}|${text.box.w}|${text.box.h}|${JSON.stringify(text.runs)}`
}

function FittedText({ text, origin, strokeInset }: {
  text: SceneText
  origin: Point
  strokeInset: number
}) {
  const boxRef = useRef<HTMLDivElement>(null)
  const key = fitKey(text)
  useLayoutEffect(() => {
    const box = boxRef.current!
    const known = fittedSizes.get(key)
    if (known !== undefined || !text.shrink) {
      box.style.fontSize = `${known ?? text.size}px`
      return
    }
    const content = box.firstElementChild as HTMLElement
    const fits = (size: number) => {
      box.style.fontSize = `${size}px`
      return content.offsetHeight <= box.clientHeight
    }
    let size = text.size
    if (!fits(size)) {
      let low = minTextSize
      let high = text.size
      while (high - low > 0.5) {
        const middle = (low + high) / 2
        if (fits(middle)) low = middle
        else high = middle
      }
      size = low
      box.style.fontSize = `${size}px`
    }
    fittedSizes.set(key, size)
  }, [key])
  return (
    <div
      ref={boxRef}
      className='canvas-text'
      data-alignment={text.alignment}
      style={{
        left: text.box.x - origin.x - strokeInset,
        top: text.box.y - origin.y - strokeInset,
        width: text.box.w,
        height: text.box.h,
        color: textColor,
      }}
    >
      <div>
        <Runs runs={text.runs} />
      </div>
    </div>
  )
}

function Runs({ runs }: { runs: TextRun[] }) {
  return runs.map((run, index) => {
    let node: ReactNode = run.text
    if (run.italic) node = <em>{node}</em>
    if (run.bold) node = <strong>{node}</strong>
    if (run.link !== undefined) {
      node = (
        <a href={run.link} target='_blank' rel='noreferrer'>
          {node}
        </a>
      )
    }
    return <span key={index}>{node}</span>
  })
}
