import type { Editor } from '@tiptap/core'
import { useEditorState } from '@tiptap/react'
import type { Frontiers, LoroDoc, UndoManager } from 'loro-crdt/web'
import { useMemo, useRef, useState } from 'react'
import type {
  Board,
  CanvasColor,
  ItemKind,
  Side,
  TextRun,
} from '~/lib/canvas/board'
import type { Camera } from '~/lib/canvas/camera'
import {
  CanvasEditError,
  CanvasEditor,
  defaultColor,
  defaultSize,
} from '~/lib/canvas/editor'
import {
  chrome,
  type Corner,
  type End,
  handleAt,
  handlesOf,
  hitAt,
  marqueeHits,
  movedBoard,
  noSelection,
  offsetBoard,
  rectBetween,
  resizedBoard,
  resizedFrame,
  sectionUnder,
  type Selection,
  targetAt,
  type Tool,
  withinClick,
} from '~/lib/canvas/interaction'
import {
  anchor,
  boundsOf,
  type CanvasScene,
  connectorBounds,
  type Point,
  type Rect,
  sceneOf,
  textLayoutOf,
} from '~/lib/canvas/scene'
import { finishText } from '~/lib/canvas/text-edit'
import {
  type BarMode,
  CameraStore,
  ChromeLayer,
  ContextBar,
  type Overlay,
  ToolStrip,
} from './canvas-chrome'
import { FilePicker } from './canvas-file-picker'
import { editLink, TextEditor, typedRuns } from './canvas-text'
import { type CanvasInput, CanvasView } from './canvas-view'

// A board someone may write: native's LiveCanvas on the web. Gestures preview
// on a copy of the board and land as one Loro commit each, so each is one
// undo step and one live update.

interface Pointer {
  start: Point
  now: Point
  // Past the click slop: a drag, not a click.
  active: boolean
}

type Drag =
  & Pointer
  & (
    | { kind: 'move'; ids: readonly string[] }
    | { kind: 'resize'; id: string; corner: Corner; frame: Rect }
    | { kind: 'marquee'; base: readonly string[] }
    | { kind: 'connect'; from: string; fromSide: Side | null }
    | { kind: 'reroute'; connector: string; end: End }
    | { kind: 'wiggle'; connector: string; vertical: boolean; offset: number }
    | { kind: 'create'; tool: ItemKind }
  )

interface Editing {
  id: string
  base: Frontiers
  original: TextRun[]
}

const doubleTapMs = 350

function previewed(board: Board, drag: Drag | null): Board {
  if (drag === null || !drag.active) return board
  const dx = drag.now.x - drag.start.x
  const dy = drag.now.y - drag.start.y
  switch (drag.kind) {
    case 'move':
      return movedBoard(board, drag.ids, dx, dy)
    case 'resize':
      return resizedBoard(
        board,
        drag.id,
        resizedFrame(drag.frame, drag.corner, dx, dy),
      )
    case 'wiggle':
      return offsetBoard(
        board,
        drag.connector,
        drag.offset + (drag.vertical ? dx : dy),
      )
    default:
      return board
  }
}

function liveSelection(board: Board, selection: Selection): Selection {
  const items = new Set(board.items.map((item) => item.id))
  const connector = selection.connector
  return {
    items: selection.items.filter((id) => items.has(id)),
    connector: connector !== null &&
        board.connectors.some((c) => c.id === connector)
      ? connector
      : null,
  }
}

const frameIn = (scene: CanvasScene, id: string) =>
  scene.items.find((item) => item.id === id)?.frame

function overlayOf(
  board: Board,
  scene: CanvasScene,
  selection: Selection,
  drag: Drag | null,
  editing: boolean,
  scale: number,
): Overlay {
  const overlay: Overlay = {
    outlines: selection.items.flatMap((id) => frameIn(scene, id) ?? []),
    handles: (scale) =>
      drag?.active || editing ? [] : handlesOf(scene, selection, scale),
    connector: selection.connector === null
      ? null
      : scene.connectors.find((c) => c.id === selection.connector)?.points ??
        null,
    marquee: null,
    drawing: null,
    target: null,
  }
  if (drag === null || !drag.active) return overlay
  if (drag.kind === 'marquee') {
    overlay.marquee = rectBetween(drag.start, drag.now)
  }
  let from: Point | undefined
  let exclude: string | undefined
  if (drag.kind === 'connect') {
    const frame = frameIn(scene, drag.from)
    from = frame &&
      (drag.fromSide === null
        ? { x: frame.x + frame.w / 2, y: frame.y + frame.h / 2 }
        : anchor(frame, drag.fromSide))
    exclude = drag.from
  }
  if (drag.kind === 'reroute') {
    const points = scene.connectors.find((c) => c.id === drag.connector)
      ?.points
    from = drag.end === 'from' ? points?.at(-1) : points?.[0]
    exclude = otherEnd(board, drag)
  }
  if (from === undefined || exclude === undefined) return overlay
  overlay.drawing = { from, to: drag.now }
  const target = targetAt(scene, drag.now, scale, exclude)
  const frame = target && frameIn(scene, target.id)
  if (target && frame) {
    overlay.target = {
      frame,
      pin: target.side === null ? null : anchor(frame, target.side),
    }
  }
  return overlay
}

// The item at the end a reroute keeps.
const otherEnd = (board: Board, drag: { connector: string; end: End }) =>
  board.connectors.find((c) => c.id === drag.connector)?.[
    drag.end === 'from' ? 'to' : 'from'
  ]

export function CanvasEditing({
  doc,
  board,
  undo,
  imageSrc,
  find,
}: {
  doc: LoroDoc
  board: Board
  undo: UndoManager
  imageSrc(path: string): string | null
  find(glob: string, limit: number): Promise<string[]>
}) {
  const store = useMemo(() => new CameraStore(), [])
  const [tool, setTool] = useState<Tool>('select')
  const [selection, setSelection] = useState<Selection>(noSelection)
  const [drag, setDrag] = useState<Drag | null>(null)
  const [editing, setEditing] = useState<Editing | null>(null)
  const [textEditor, setTextEditor] = useState<Editor | null>(null)
  const [picking, setPicking] = useState<Point | null>(null)

  const shown = useMemo(() => previewed(board, drag), [board, drag])
  const scene = useMemo(() => sceneOf(shown), [shown])
  const live = useMemo(() => liveSelection(board, selection), [
    board,
    selection,
  ])

  // The handlers outlive renders and read the latest state here.
  const now = useRef({ board, scene, selection: live, tool, drag, editing })
  now.current = {
    ...now.current,
    board,
    scene,
    selection: live,
    tool,
    editing,
  }
  const editorRef = useRef<Editor | null>(null)
  editorRef.current = textEditor
  const lastTap = useRef<{ id: string; at: number } | null>(null)

  const select = (next: Selection) => {
    now.current.selection = next
    setSelection(next)
  }
  const dragTo = (next: Drag | null) => {
    now.current.drag = next
    setDrag(next)
  }
  const edit = (change: (editor: CanvasEditor) => void) => {
    try {
      change(new CanvasEditor(doc))
    } catch (error) {
      // Someone else deleted what this edit names.
      if (!(error instanceof CanvasEditError)) throw error
    }
    doc.commit()
  }

  const beginEditing = (id: string, original: TextRun[]) => {
    const next = { id, base: doc.frontiers(), original }
    now.current.editing = next
    setEditing(next)
    select({ items: [id], connector: null })
  }
  const endEditing = () => {
    const session = now.current.editing
    if (session === null) return
    now.current.editing = null
    setEditing(null)
    const typedIn = editorRef.current
    if (typedIn === null) return
    try {
      finishText(doc, session, typedRuns(typedIn))
    } catch (error) {
      if (!(error instanceof CanvasEditError)) throw error
    }
  }

  const insertAt = (kind: ItemKind, at: Point, path?: string) => {
    const size = defaultSize[kind]
    const frame = { x: at.x - size.w / 2, y: at.y - size.h / 2, ...size }
    const section = kind === 'section'
      ? null
      : sectionUnder(now.current.scene, at, '')
    let id: string | null = null
    edit((e) => {
      id = e.insert(kind, frame, defaultColor[kind], { path, section })
    })
    setTool('select')
    if (id === null) return
    if (kind === 'file' || kind === 'section') {
      select({ items: [id], connector: null })
    } else beginEditing(id, [])
  }

  const removeSelection = () => {
    const { items, connector } = now.current.selection
    if (connector !== null) edit((e) => e.deleteConnector(connector))
    else if (items.length > 0) edit((e) => e.delete([...items]))
    select(noSelection)
  }
  const duplicateSelection = () => {
    const { items } = now.current.selection
    if (items.length === 0) return
    let copies = new Map<string, string>()
    edit((e) => {
      copies = e.duplicate(
        [...items],
        chrome.duplicateOffset,
        chrome.duplicateOffset,
      )
    })
    select({
      items: items.flatMap((id) => copies.get(id) ?? []),
      connector: null,
    })
  }
  const history = {
    canUndo: undo.canUndo(),
    canRedo: undo.canRedo(),
    undo: () => {
      endEditing()
      undo.undo()
    },
    redo: () => {
      endEditing()
      undo.redo()
    },
  }
  const historyRef = useRef(history)
  historyRef.current = history

  const down = (event: PointerEvent, at: Point, camera: Camera): boolean => {
    endEditing()
    const { scene, selection, tool } = now.current
    const scale = camera.scale
    const pointer = { start: at, now: at, active: false }
    if (tool !== 'select' && tool !== 'connector') {
      dragTo({ ...pointer, kind: 'create', tool })
      return true
    }
    if (tool === 'select') {
      const handle = handleAt(handlesOf(scene, selection, scale), at, scale)
      switch (handle?.kind) {
        case 'corner': {
          const frame = frameIn(scene, handle.id)
          if (frame === undefined) break
          dragTo({
            ...pointer,
            kind: 'resize',
            id: handle.id,
            corner: handle.corner,
            frame,
          })
          return true
        }
        case 'side':
          dragTo({
            ...pointer,
            kind: 'connect',
            from: handle.id,
            fromSide: handle.side,
          })
          return true
        case 'end':
          dragTo({
            ...pointer,
            kind: 'reroute',
            connector: handle.connector,
            end: handle.end,
          })
          return true
        case 'wiggle': {
          const offset = now.current.board.connectors.find((c) =>
            c.id === handle.connector
          )?.offset ?? 0
          dragTo({
            ...pointer,
            kind: 'wiggle',
            connector: handle.connector,
            vertical: handle.vertical,
            offset,
          })
          return true
        }
      }
    }
    const hit = hitAt(scene, at, scale)
    if (tool === 'connector') {
      if (hit === null || !('item' in hit)) return false
      dragTo({ ...pointer, kind: 'connect', from: hit.item.id, fromSide: null })
      return true
    }
    if (hit !== null && 'item' in hit) {
      const id = hit.item.id
      if (event.shiftKey) {
        select({
          items: selection.items.includes(id)
            ? selection.items.filter((other) => other !== id)
            : [...selection.items, id],
          connector: null,
        })
        return true
      }
      const items = selection.items.includes(id) ? selection.items : [id]
      select({ items, connector: null })
      dragTo({ ...pointer, kind: 'move', ids: items })
      return true
    }
    if (hit !== null) {
      select({ items: [], connector: hit.connector.id })
      return true
    }
    if (event.pointerType === 'touch') {
      select(noSelection)
      return false
    }
    const base = event.shiftKey ? selection.items : []
    select({ items: base, connector: null })
    dragTo({ ...pointer, kind: 'marquee', base })
    return true
  }

  const move = (_: PointerEvent, at: Point, camera: Camera) => {
    const current = now.current.drag
    if (current === null) return
    const active = current.active ||
      !withinClick(current.start, at, camera.scale)
    const next = { ...current, now: at, active }
    dragTo(next)
    if (next.kind === 'marquee' && active) {
      const hits = marqueeHits(
        sceneOf(now.current.board),
        rectBetween(next.start, at),
      )
      select({
        items: [...new Set([...next.base, ...hits])],
        connector: null,
      })
    }
  }

  const up = (
    event: PointerEvent,
    at: Point,
    camera: Camera,
    cancelled: boolean,
  ) => {
    const current = now.current.drag
    dragTo(null)
    if (current === null || cancelled) return
    const { board, scene } = now.current
    const scale = camera.scale
    const dx = at.x - current.start.x
    const dy = at.y - current.start.y
    const active = current.active || !withinClick(current.start, at, scale)
    switch (current.kind) {
      case 'create':
        if (!withinClick(current.start, at, scale)) return
        if (current.tool === 'file') {
          setTool('select')
          setPicking(at)
        } else insertAt(current.tool, at)
        return
      case 'move': {
        if (!active) {
          const id = current.ids.length === 1 ? current.ids[0] : null
          const last = lastTap.current
          const t = performance.now()
          lastTap.current = id === null ? null : { id, at: t }
          if (
            event.pointerType === 'touch' && id !== null &&
            last?.id === id && t - last.at < doubleTapMs
          ) startEditing(id)
          return
        }
        const ids = current.ids
        const after = sceneOf(movedBoard(board, ids, dx, dy))
        const moving = new Set(ids)
        edit((e) => {
          e.move([...ids], dx, dy)
          for (const item of board.items) {
            if (!moving.has(item.id) || item.kind === 'section') continue
            if (item.parent !== null && moving.has(item.parent)) continue
            const frame = frameIn(after, item.id)
            if (frame === undefined) continue
            const centre = {
              x: frame.x + frame.w / 2,
              y: frame.y + frame.h / 2,
            }
            const into = sectionUnder(after, centre, item.id)
            if (into !== item.parent) e.reparent(item.id, into)
          }
        })
        return
      }
      case 'resize':
        if (active) {
          edit((e) =>
            e.setFrame(
              current.id,
              resizedFrame(current.frame, current.corner, dx, dy),
            )
          )
        }
        return
      case 'connect': {
        const target = targetAt(scene, at, scale, current.from)
        if (target === null) return
        let id: string | null = null
        edit((e) => {
          id = e.connect({
            from: current.from,
            to: target.id,
            fromSide: current.fromSide ?? undefined,
            toSide: target.side ?? undefined,
            style: 'straight',
            arrow: 'end',
          })
        })
        setTool('select')
        if (id !== null) select({ items: [], connector: id })
        return
      }
      case 'reroute': {
        const kept = otherEnd(board, current)
        if (kept === undefined) return
        const target = targetAt(scene, at, scale, kept)
        if (target === null) return
        edit((e) =>
          e.updateConnector(current.connector, (c) => {
            if (current.end === 'from') {
              c.from = target.id
              c.fromSide = target.side ?? undefined
            } else {
              c.to = target.id
              c.toSide = target.side ?? undefined
            }
          })
        )
        return
      }
      case 'wiggle':
        if (active) {
          edit((e) =>
            e.updateConnector(current.connector, (c) => {
              c.offset = current.offset + (current.vertical ? dx : dy)
            })
          )
        }
        return
      case 'marquee':
        return
    }
  }

  const startEditing = (id: string) => {
    const item = now.current.board.items.find((i) => i.id === id)
    if (item === undefined || item.kind === 'file' || item.note) return
    beginEditing(id, item.text)
  }

  const key = (event: KeyboardEvent) => {
    const mod = event.metaKey || event.ctrlKey
    const { selection, tool, drag } = now.current
    const chosen = selection.items.length > 0 || selection.connector !== null
    switch (event.key) {
      case 'Escape':
        if (drag === null && !chosen && tool === 'select') return
        dragTo(null)
        select(noSelection)
        setTool('select')
        break
      case 'Delete':
      case 'Backspace':
        if (!chosen) return
        removeSelection()
        break
      case 'Enter':
        if (selection.items.length !== 1) return
        startEditing(selection.items[0])
        break
      case 'd':
        if (!mod) return
        duplicateSelection()
        break
      case 'z':
      case 'Z':
        if (!mod) return
        if (event.shiftKey) historyRef.current.redo()
        else historyRef.current.undo()
        break
      case 'y':
        if (!mod) return
        historyRef.current.redo()
        break
      default:
        return
    }
    event.preventDefault()
    event.stopPropagation()
  }

  const handlers = useRef({ down, move, up, key, startEditing })
  handlers.current = { down, move, up, key, startEditing }
  const input = useMemo<CanvasInput>(() => ({
    down: (...args) => handlers.current.down(...args),
    move: (...args) => handlers.current.move(...args),
    up: (...args) => handlers.current.up(...args),
    key: (event) => handlers.current.key(event),
    doubleClick: (at, camera) => {
      const hit = hitAt(now.current.scene, at, camera.scale)
      if (hit !== null && 'item' in hit) {
        handlers.current.startEditing(hit.item.id)
      }
    },
  }), [])

  const marks = useEditorState({
    editor: textEditor,
    selector: ({ editor }) =>
      editor === null ? null : {
        bold: editor.isActive('bold'),
        italic: editor.isActive('italic'),
        link: editor.isActive('link'),
      },
  })

  const edited = editing === null
    ? undefined
    : board.items.find((item) => item.id === editing.id)
  const editedFrame = edited && frameIn(scene, edited.id)

  let bar: { anchor: Rect; mode: BarMode } | null = null
  if (drag?.active) bar = null
  else if (editing !== null) {
    if (editedFrame && textEditor !== null && marks !== null) {
      bar = {
        anchor: editedFrame,
        mode: {
          kind: 'text',
          ...marks,
          toggleBold: () => textEditor.chain().focus().toggleBold().run(),
          toggleItalic: () => textEditor.chain().focus().toggleItalic().run(),
          editLink: () => editLink(textEditor),
        },
      }
    }
  } else if (live.connector !== null) {
    const id = live.connector
    const connector = board.connectors.find((c) => c.id === id)!
    const drawn = scene.connectors.find((c) => c.id === id)
    if (drawn !== undefined) {
      bar = {
        anchor: connectorBounds(drawn),
        mode: {
          kind: 'connector',
          style: connector.style,
          arrow: connector.arrow,
          setStyle: (style) =>
            edit((e) =>
              e.updateConnector(id, (c) => {
                if (c.style !== style) c.offset = 0
                c.style = style
              })
            ),
          setArrow: (arrow) =>
            edit((e) => e.updateConnector(id, (c) => (c.arrow = arrow))),
          remove: removeSelection,
        },
      }
    }
  } else if (live.items.length > 0) {
    const bounds = boundsOf(
      live.items.flatMap((id) => frameIn(scene, id) ?? []),
    )
    const coloured = board.items.filter((item) =>
      live.items.includes(item.id) && defaultColor[item.kind] !== null
    )
    const shared = coloured.every((item) => item.color === coloured[0].color)
    if (bounds !== null) {
      bar = {
        anchor: bounds,
        mode: {
          kind: 'items',
          ...(coloured.length === 0
            ? {}
            : { color: shared ? coloured[0].color ?? null : null }),
          setColor: (color: CanvasColor) =>
            edit((e) => e.setColor(coloured.map((item) => item.id), color)),
          duplicate: duplicateSelection,
          remove: removeSelection,
        },
      }
    }
  }

  return (
    <div className='canvas-editing' data-tool={tool}>
      <CanvasView
        scene={scene}
        imageSrc={imageSrc}
        onFrame={store.set}
        input={input}
        editingText={editing?.id ?? null}
      >
        <ChromeLayer
          store={store}
          overlay={overlayOf(
            board,
            scene,
            live,
            drag,
            editing !== null,
            store.get().scale,
          )}
        />
        {editing !== null && edited !== undefined && editedFrame && (
          <TextEditor
            key={editing.id}
            store={store}
            kind={edited.kind}
            layout={textLayoutOf(edited, editedFrame)}
            runs={editing.original}
            onEditor={setTextEditor}
            onDone={endEditing}
          />
        )}
        {bar !== null && (
          <ContextBar store={store} anchor={bar.anchor} mode={bar.mode} />
        )}
        <ToolStrip
          tool={tool}
          onTool={(next) => {
            endEditing()
            setTool(next)
          }}
          undo={history}
        />
      </CanvasView>
      <FilePicker
        open={picking !== null}
        find={find}
        onPick={(path) => {
          if (picking !== null) insertAt('file', picking, path)
          setPicking(null)
        }}
        onClose={() => setPicking(null)}
      />
    </div>
  )
}
