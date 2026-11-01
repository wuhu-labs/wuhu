import { LoroDoc } from 'loro-crdt/web'
import { loadLoro } from '~/lib/wmd/loro.ts'
import json from './editor-cases.json' with { type: 'json' }
import {
  type Arrow,
  boardOf,
  type CanvasColor,
  configuredBoard,
  type ConnectorStyle,
  idPattern,
  type ItemKind,
  type Side,
  type TextRun,
} from './board.ts'
import { CanvasEditError, CanvasEditor } from './editor.ts'

// editor-cases.json is CanvasDocument's CanvasEditor fixture
// (packages/wuhu-core/Targets/CanvasDocument/Tests/Fixtures): the Swift editor
// passes the same cases.

interface Change {
  from?: string
  to?: string
  fromSide?: Side | null
  toSide?: Side | null
  style?: ConnectorStyle
  offset?: number
  arrow?: Arrow
  label?: TextRun[]
}

interface Operation {
  op: string
  as?: string | Record<string, string>
  kind?: ItemKind
  frame?: [number, number, number, number]
  color?: CanvasColor
  text?: TextRun[]
  path?: string
  in?: string
  id?: string
  ids?: string[]
  into?: string
  dx?: number
  dy?: number
  from?: string
  to?: string
  fromSide?: Side
  toSide?: Side
  style?: ConnectorStyle
  arrow?: Arrow
  label?: TextRun[]
  set?: Change
  deleted?: { items: string[]; connectors: string[] }
  throws?: string
  noop?: boolean
}

interface Case {
  name: string
  ops: Operation[]
  expected: unknown
}

await loadLoro()

const cases = json as unknown as Case[]

function canonical(value: unknown): string {
  return JSON.stringify(
    value,
    (_, v) =>
      v !== null && typeof v === 'object' && !Array.isArray(v)
        ? Object.fromEntries(
          Object.entries(v).sort(([a], [b]) => a < b ? -1 : 1),
        )
        : v,
  )
}

function equal(actual: unknown, expected: unknown, what: string) {
  const a = canonical(actual)
  const e = canonical(expected)
  if (a !== e) throw new Error(`${what}: expected ${e}\n     got ${a}`)
}

class Runner {
  readonly names = new Map<string, string>()
  constructor(readonly doc: LoroDoc) {}

  id = (name: string) => this.names.get(name) ?? name
  name = (id: string) => [...this.names].find(([, v]) => v === id)?.[0] ?? 'new'

  run(op: Operation) {
    const editor = new CanvasEditor(this.doc)
    const frame = op.frame &&
      { x: op.frame[0], y: op.frame[1], w: op.frame[2], h: op.frame[3] }
    switch (op.op) {
      case 'insert': {
        const id = editor.insert(op.kind!, frame!, op.color ?? null, {
          text: op.text,
          path: op.path,
          section: op.in === undefined ? null : this.id(op.in),
        })
        if (typeof op.as === 'string') this.names.set(op.as, id)
        return
      }
      case 'setFrame':
        return editor.setFrame(this.id(op.id!), frame!)
      case 'move':
        return editor.move(op.ids!.map(this.id), op.dx!, op.dy!)
      case 'reparent':
        return editor.reparent(
          this.id(op.id!),
          op.into === undefined ? null : this.id(op.into),
        )
      case 'bringToFront':
        return editor.bringToFront(this.id(op.id!))
      case 'delete': {
        const deletion = editor.delete(op.ids!.map(this.id))
        equal(
          {
            items: deletion.items.map(this.name).sort(),
            connectors: deletion.connectors.map(this.name).sort(),
          },
          op.deleted && {
            items: [...op.deleted.items].sort(),
            connectors: [...op.deleted.connectors].sort(),
          },
          'deletion',
        )
        return
      }
      case 'duplicate': {
        const copies = editor.duplicate(op.ids!.map(this.id), op.dx!, op.dy!)
        if (typeof op.as === 'object') {
          for (const [original, name] of Object.entries(op.as)) {
            this.names.set(name, copies.get(this.id(original))!)
          }
        }
        return
      }
      case 'setColor':
        return editor.setColor(op.ids!.map(this.id), op.color ?? null)
      case 'setKind':
        return editor.setKind(this.id(op.id!), op.kind!)
      case 'setText':
        return editor.setText(this.id(op.id!), op.text ?? [])
      case 'setPath':
        return editor.setPath(this.id(op.id!), op.path!)
      case 'connect': {
        const id = editor.connect({
          from: this.id(op.from!),
          to: this.id(op.to!),
          fromSide: op.fromSide,
          toSide: op.toSide,
          style: op.style ?? 'straight',
          arrow: op.arrow ?? 'end',
          label: op.label ?? [],
        })
        if (typeof op.as === 'string') this.names.set(op.as, id)
        return
      }
      case 'updateConnector': {
        const change = op.set!
        return editor.updateConnector(this.id(op.id!), (connector) => {
          if (change.from !== undefined) connector.from = this.id(change.from)
          if (change.to !== undefined) connector.to = this.id(change.to)
          if (change.fromSide !== undefined) {
            connector.fromSide = change.fromSide ?? undefined
          }
          if (change.toSide !== undefined) {
            connector.toSide = change.toSide ?? undefined
          }
          if (change.style !== undefined) connector.style = change.style
          if (change.offset !== undefined) connector.offset = change.offset
          if (change.arrow !== undefined) connector.arrow = change.arrow
          if (change.label !== undefined) connector.label = change.label
        })
      }
      case 'deleteConnector':
        return editor.deleteConnector(this.id(op.id!))
      default:
        throw new Error(`unknown op ${op.op}`)
    }
  }

  board() {
    const board = boardOf(this.doc)
    const runs = (text: TextRun[]) => text.length === 0 ? {} : { text }
    return {
      items: board.items.map((item) => ({
        id: this.name(item.id),
        kind: item.kind,
        ...(item.parent === null ? {} : { parent: this.name(item.parent) }),
        x: item.x,
        y: item.y,
        w: item.w,
        h: item.h,
        ...(item.color === undefined ? {} : { color: item.color }),
        ...runs(item.text),
        ...(item.path === undefined ? {} : { path: item.path }),
      })),
      connectors: board.connectors.map((c) => ({
        id: this.name(c.id),
        from: this.name(c.from),
        to: this.name(c.to),
        ...(c.fromSide === undefined ? {} : { fromSide: c.fromSide }),
        ...(c.toSide === undefined ? {} : { toSide: c.toSide }),
        style: c.style,
        offset: c.offset,
        arrow: c.arrow,
        ...(c.label.length === 0 ? {} : { label: c.label }),
      })).sort((a, b) =>
        canonical([a.id, a.from, a.to]) < canonical([b.id, b.from, b.to])
          ? -1
          : 1
      ),
    }
  }
}

const version = (doc: LoroDoc) =>
  canonical(Object.fromEntries(doc.oplogVersion().toJSON()))

for (const c of cases) {
  Deno.test(`editor fixture: ${c.name}`, () => {
    const doc = configuredBoard(new LoroDoc())
    const runner = new Runner(doc)
    c.ops.forEach((op, index) => {
      const before = version(doc)
      let thrown: string | undefined
      try {
        runner.run(op)
      } catch (error) {
        if (!(error instanceof CanvasEditError)) throw error
        thrown = error.kind
      }
      equal(thrown, op.throws, `op ${index} (${op.op}) error`)
      doc.commit()
      if (op.noop === true || op.throws !== undefined) {
        equal(version(doc), before, `op ${index} (${op.op}) writes`)
      }
    })
    equal(runner.board(), c.expected, 'board')
    const read = boardOf(doc)
    for (const { id } of [...read.items, ...read.connectors]) {
      if (!idPattern.test(id)) throw new Error(`bad id ${id}`)
    }
  })
}
