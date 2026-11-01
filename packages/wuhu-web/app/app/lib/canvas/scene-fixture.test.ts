import json from './scene-cases.json' with { type: 'json' }
import type { Board, BoardConnector, BoardItem, TextRun } from './board.ts'
import { type Rect, sceneOf } from './scene.ts'

// scene-cases.json is CanvasDocument's CanvasScene fixture
// (packages/wuhu-core/Targets/CanvasDocument/Tests/Fixtures): the Swift scene
// builder passes the same cases.

interface Case {
  name: string
  items: (Omit<BoardItem, 'parent' | 'text'> & {
    parent?: string
    text?: string
  })[]
  connectors: (Omit<BoardConnector, 'offset' | 'arrow' | 'label'> & {
    offset?: number
    arrow?: BoardConnector['arrow']
    label?: string
  })[]
  expected: unknown
}

const cases = json as Case[]

const runs = (text: string | undefined): TextRun[] =>
  text === undefined || text === '' ? [] : [{ text }]

function boardOf(c: Case): Board {
  return {
    items: c.items.map((item) => ({
      ...item,
      parent: item.parent ?? null,
      text: runs(item.text),
    })),
    connectors: c.connectors.map((connector) => ({
      ...connector,
      offset: connector.offset ?? 0,
      arrow: connector.arrow ?? 'end',
      label: runs(connector.label),
    })),
  }
}

const tuple = (r: Rect) => [r.x, r.y, r.w, r.h]

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

for (const c of cases) {
  Deno.test(`scene fixture: ${c.name}`, () => {
    const scene = sceneOf(boardOf(c))
    const actual = {
      items: scene.items.map((item) => ({
        id: item.id,
        frame: tuple(item.frame),
        ...(item.fill === undefined ? {} : { fill: item.fill }),
        ...(item.stroke === undefined ? {} : { stroke: item.stroke }),
        ...(item.image === undefined ? {} : { image: item.image.path }),
      })),
      connectors: scene.connectors.map((connector) => ({
        id: connector.id,
        points: connector.points.map(({ x, y }) => [x, y]),
        arrow: connector.arrow,
        ...(connector.label === undefined ? {} : {
          labelAnchor: [connector.label.anchor.x, connector.label.anchor.y],
        }),
      })),
    }
    const a = canonical(actual)
    const e = canonical(c.expected)
    if (a !== e) throw new Error(`expected ${e}\n     got ${a}`)
  })
}
