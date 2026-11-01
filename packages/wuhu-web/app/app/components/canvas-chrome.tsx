import { Glass, GlassButton, Icon } from '@wuhu/ui'
import {
  type ReactNode,
  useLayoutEffect,
  useRef,
  useState,
  useSyncExternalStore,
} from 'react'
import type { Arrow, CanvasColor, ConnectorStyle } from '~/lib/canvas/board'
import { colors } from '~/lib/canvas/board'
import type { Camera } from '~/lib/canvas/camera'
import {
  barOrigin,
  chrome,
  type Handle,
  type Tool,
  tools,
} from '~/lib/canvas/interaction'
import { type Point, type Rect, swatchOf } from '~/lib/canvas/scene'

// The editing chrome over a CanvasView, in view points: selection, handles
// and drags drawn as native's BoardChrome draws them, the tool strip and the
// contextual bar. Everything here carries `canvas-chrome`, so its pointers
// neither pan nor edit the board.

export class CameraStore {
  private camera: Camera = { x: 0, y: 0, scale: 1 }
  private readonly listeners = new Set<() => void>()
  readonly set = (camera: Camera) => {
    this.camera = camera
    for (const listener of this.listeners) listener()
  }
  readonly get = () => this.camera
  readonly subscribe = (listener: () => void) => {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }
}

export function useCamera(store: CameraStore): Camera {
  return useSyncExternalStore(store.subscribe, store.get, store.get)
}

export const viewPoint = (camera: Camera, p: Point): Point => ({
  x: (p.x - camera.x) * camera.scale,
  y: (p.y - camera.y) * camera.scale,
})

export const viewRect = (camera: Camera, r: Rect): Rect => ({
  ...viewPoint(camera, r),
  w: r.w * camera.scale,
  h: r.h * camera.scale,
})

const accent = 'var(--color-blue)'

export interface Overlay {
  outlines: Rect[]
  handles(scale: number): Handle[]
  connector: Point[] | null
  marquee: Rect | null
  drawing: { from: Point; to: Point } | null
  target: { frame: Rect; pin: Point | null } | null
}

export function ChromeLayer({ store, overlay }: {
  store: CameraStore
  overlay: Overlay
}) {
  const camera = useCamera(store)
  const v = (p: Point) => viewPoint(camera, p)
  const r = (rect: Rect, outset: number) => {
    const view = viewRect(camera, rect)
    return {
      x: view.x - outset,
      y: view.y - outset,
      width: view.w + 2 * outset,
      height: view.h + 2 * outset,
    }
  }
  const line = (points: Point[]) =>
    points.map(v).map((p) => `${p.x},${p.y}`).join(' ')
  return (
    <svg className='canvas-chrome canvas-overlay' aria-hidden='true'>
      {overlay.connector && (
        <polyline
          points={line(overlay.connector)}
          stroke={accent}
          strokeOpacity={0.3}
          strokeWidth={6}
        />
      )}
      {overlay.outlines.map((outline, i) => (
        <rect key={i} {...r(outline, 2)} stroke={accent} strokeWidth={1.5} />
      ))}
      {overlay.handles(camera.scale).map((handle, i) => {
        const at = v(handle.at)
        switch (handle.kind) {
          case 'corner':
            return (
              <rect
                key={i}
                x={at.x - chrome.corner / 2}
                y={at.y - chrome.corner / 2}
                width={chrome.corner}
                height={chrome.corner}
                rx={2}
                fill='#fff'
                stroke={accent}
                strokeWidth={1.5}
              />
            )
          case 'side': {
            const arm = 2.5
            return (
              <g key={i}>
                <circle
                  cx={at.x}
                  cy={at.y}
                  r={chrome.side / 2}
                  fill={accent}
                  fillOpacity={0.85}
                />
                <path
                  d={`M${at.x - arm},${at.y}h${2 * arm}M${at.x},${at.y - arm}v${
                    2 * arm
                  }`}
                  stroke='#fff'
                  strokeWidth={1.5}
                />
              </g>
            )
          }
          case 'end':
            return (
              <circle
                key={i}
                cx={at.x}
                cy={at.y}
                r={chrome.end / 2}
                fill='#fff'
                stroke={accent}
                strokeWidth={1.5}
              />
            )
          case 'wiggle': {
            const long = 18
            const short = chrome.end - 2
            const w = handle.vertical ? short : long
            const h = handle.vertical ? long : short
            return (
              <rect
                key={i}
                x={at.x - w / 2}
                y={at.y - h / 2}
                width={w}
                height={h}
                rx={short / 2}
                fill={accent}
                stroke='#fff'
              />
            )
          }
        }
      })}
      {overlay.marquee && (
        <rect
          {...r(overlay.marquee, 0)}
          fill={accent}
          fillOpacity={0.08}
          stroke={accent}
          strokeWidth={1}
        />
      )}
      {overlay.target && (
        <rect
          {...r(overlay.target.frame, 3)}
          rx={4}
          stroke={accent}
          strokeWidth={2}
        />
      )}
      {overlay.target?.pin && (
        <circle
          cx={v(overlay.target.pin).x}
          cy={v(overlay.target.pin).y}
          r={4}
          fill={accent}
        />
      )}
      {overlay.drawing && (
        <line
          x1={v(overlay.drawing.from).x}
          y1={v(overlay.drawing.from).y}
          x2={v(overlay.drawing.to).x}
          y2={v(overlay.drawing.to).y}
          stroke={accent}
          strokeWidth={1.5}
          strokeDasharray='5 4'
        />
      )}
    </svg>
  )
}

const toolNames: Record<Tool, string> = {
  select: 'Select',
  sticky: 'Sticky note',
  text: 'Text',
  rect: 'Rectangle',
  ellipse: 'Ellipse',
  diamond: 'Diamond',
  connector: 'Connector',
  section: 'Section',
  file: 'File',
}

// Strokes drawn in a 20-point box where IconaMoon has no glyph.
function Stroked({ children }: { children: ReactNode }) {
  return (
    <svg
      className='canvas-glyph'
      width={20}
      height={20}
      viewBox='0 0 20 20'
      aria-hidden='true'
    >
      {children}
    </svg>
  )
}

function toolIcon(tool: Tool): ReactNode {
  switch (tool) {
    case 'select':
      return <Icon name='cursor' />
    case 'sticky':
      return (
        <Stroked>
          <path d='M4 4h12v8l-4 4H4z M12 16v-4h4' />
        </Stroked>
      )
    case 'text':
      return <Icon name='type' />
    case 'rect':
      return (
        <Stroked>
          <rect x={3.5} y={5} width={13} height={10} rx={1.5} />
        </Stroked>
      )
    case 'ellipse':
      return (
        <Stroked>
          <circle cx={10} cy={10} r={6.5} />
        </Stroked>
      )
    case 'diamond':
      return (
        <Stroked>
          <path d='M10 3.5l6.5 6.5-6.5 6.5-6.5-6.5z' />
        </Stroked>
      )
    case 'connector':
      return <Icon name='arrow-top-right-1' />
    case 'section':
      return (
        <Stroked>
          <rect
            x={3.5}
            y={5}
            width={13}
            height={10}
            rx={1.5}
            strokeDasharray='2.5 2'
          />
        </Stroked>
      )
    case 'file':
      return <Icon name='file' />
  }
}

// Chrome buttons leave focus where it was: in the text editor, its selection;
// on the board, its keyboard shortcuts.
const keepFocus = (event: { preventDefault(): void }) => event.preventDefault()

export function ToolStrip({ tool, onTool, undo }: {
  tool: Tool
  onTool(tool: Tool): void
  undo: {
    canUndo: boolean
    canRedo: boolean
    undo(): void
    redo(): void
  }
}) {
  return (
    <div
      className='canvas-chrome canvas-tools'
      role='toolbar'
      aria-label='Tools'
    >
      {tools.map((t) => (
        <GlassButton
          key={t}
          solid={tool === t}
          aria-pressed={tool === t}
          aria-label={toolNames[t]}
          title={toolNames[t]}
          onPointerDown={keepFocus}
          onMouseDown={keepFocus}
          onClick={() => onTool(t)}
        >
          {toolIcon(t)}
        </GlassButton>
      ))}
      <div className='canvas-tools-gap' />
      <GlassButton
        aria-label='Undo'
        title='Undo'
        disabled={!undo.canUndo}
        onPointerDown={keepFocus}
        onMouseDown={keepFocus}
        onClick={undo.undo}
      >
        <Icon name='do-undo' />
      </GlassButton>
      <GlassButton
        aria-label='Redo'
        title='Redo'
        disabled={!undo.canRedo}
        onPointerDown={keepFocus}
        onMouseDown={keepFocus}
        onClick={undo.redo}
      >
        <Icon name='do-redo' />
      </GlassButton>
    </div>
  )
}

export type BarMode =
  | {
    kind: 'items'
    // Absent: nothing selected takes a colour; null: the colours differ.
    color?: CanvasColor | null
    setColor(color: CanvasColor): void
    duplicate(): void
    remove(): void
  }
  | {
    kind: 'connector'
    style: ConnectorStyle
    arrow: Arrow
    setStyle(style: ConnectorStyle): void
    setArrow(arrow: Arrow): void
    remove(): void
  }
  | {
    kind: 'text'
    bold: boolean
    italic: boolean
    link: boolean
    toggleBold(): void
    toggleItalic(): void
    editLink(): void
  }

const colorNames: Record<CanvasColor, string> = {
  yellow: 'Yellow',
  pink: 'Pink',
  green: 'Green',
  blue: 'Blue',
  purple: 'Purple',
  gray: 'Gray',
}

function BarButton({ label, active, onClick, children }: {
  label: string
  active?: boolean
  onClick(): void
  children: ReactNode
}) {
  return (
    <GlassButton
      solid={active}
      aria-pressed={active}
      aria-label={label}
      title={label}
      onPointerDown={keepFocus}
      onMouseDown={keepFocus}
      onClick={onClick}
    >
      {children}
    </GlassButton>
  )
}

function barContent(mode: BarMode): ReactNode {
  switch (mode.kind) {
    case 'items':
      return (
        <>
          {mode.color !== undefined && (
            <Glass className='canvas-swatches' role='group' aria-label='Colour'>
              {colors.map((color) => (
                <button
                  key={color}
                  type='button'
                  className='canvas-swatch'
                  aria-label={colorNames[color]}
                  aria-pressed={mode.color === color}
                  title={colorNames[color]}
                  onPointerDown={keepFocus}
                  onMouseDown={keepFocus}
                  onClick={() => mode.setColor(color)}
                >
                  <span style={{ background: swatchOf(color) }} />
                </button>
              ))}
            </Glass>
          )}
          <div className='canvas-bar-group'>
            <BarButton label='Duplicate' onClick={mode.duplicate}>
              <Icon name='copy' />
            </BarButton>
            <BarButton label='Delete' onClick={mode.remove}>
              <Icon name='trash' />
            </BarButton>
          </div>
        </>
      )
    case 'connector':
      return (
        <>
          <div className='canvas-bar-group'>
            <BarButton
              label='Straight'
              active={mode.style === 'straight'}
              onClick={() => mode.setStyle('straight')}
            >
              <Stroked>
                <path d='M5 15L15 5' />
              </Stroked>
            </BarButton>
            <BarButton
              label='Elbow'
              active={mode.style === 'elbow'}
              onClick={() => mode.setStyle('elbow')}
            >
              <Stroked>
                <path d='M4 5h6v10h6' />
              </Stroked>
            </BarButton>
          </div>
          <div className='canvas-bar-group'>
            <BarButton
              label='No arrow'
              active={mode.arrow === 'none'}
              onClick={() => mode.setArrow('none')}
            >
              <Icon name='sign-minus' />
            </BarButton>
            <BarButton
              label='Arrow at end'
              active={mode.arrow === 'end'}
              onClick={() => mode.setArrow('end')}
            >
              <Icon name='arrow-right-1' />
            </BarButton>
            <BarButton
              label='Arrows at both ends'
              active={mode.arrow === 'both'}
              onClick={() => mode.setArrow('both')}
            >
              <Stroked>
                <path d='M3.5 10h13M6.5 7l-3 3 3 3M13.5 7l3 3-3 3' />
              </Stroked>
            </BarButton>
          </div>
          <BarButton label='Delete' onClick={mode.remove}>
            <Icon name='trash' />
          </BarButton>
        </>
      )
    case 'text':
      return (
        <div className='canvas-bar-group' role='group' aria-label='Marks'>
          <BarButton label='Bold' active={mode.bold} onClick={mode.toggleBold}>
            <Stroked>
              <path
                d='M6 4h5a3 3 0 010 6H6zM6 10h6a3 3 0 010 6H6z'
                strokeWidth={2}
              />
            </Stroked>
          </BarButton>
          <BarButton
            label='Italic'
            active={mode.italic}
            onClick={mode.toggleItalic}
          >
            <Stroked>
              <path d='M9 4h6M5 16h6M12 4L8 16' />
            </Stroked>
          </BarButton>
          <BarButton label='Link' active={mode.link} onClick={mode.editLink}>
            <Icon name='link' />
          </BarButton>
        </div>
      )
  }
}

// Above the selection (`anchor`, board points), else below it.
export function ContextBar({ store, anchor, mode }: {
  store: CameraStore
  anchor: Rect
  mode: BarMode
}) {
  const camera = useCamera(store)
  const ref = useRef<HTMLDivElement>(null)
  const [size, setSize] = useState<
    { bar: { w: number; h: number }; view: { w: number; h: number } } | null
  >(null)
  useLayoutEffect(() => {
    const bar = ref.current!
    const view = bar.parentElement!
    const measure = () =>
      setSize((last) => {
        const next = {
          bar: { w: bar.offsetWidth, h: bar.offsetHeight },
          view: { w: view.clientWidth, h: view.clientHeight },
        }
        return JSON.stringify(last) === JSON.stringify(next) ? last : next
      })
    measure()
    const observer = new ResizeObserver(measure)
    observer.observe(bar)
    observer.observe(view)
    return () => observer.disconnect()
  }, [])
  const origin = size === null
    ? null
    : barOrigin(viewRect(camera, anchor), size.bar, size.view)
  return (
    <div
      ref={ref}
      className='canvas-chrome canvas-bar'
      role='toolbar'
      aria-label='Selection'
      style={origin === null
        ? { visibility: 'hidden' }
        : { transform: `translate(${origin.x}px, ${origin.y}px)` }}
    >
      {barContent(mode)}
    </div>
  )
}
