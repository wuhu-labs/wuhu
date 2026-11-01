import type { Board, BoardItem } from './board.ts'
import {
  barOrigin,
  handleAt,
  handlesOf,
  hitAt,
  marqueeHits,
  movedBoard,
  resizedFrame,
  sectionUnder,
  targetAt,
  wiggleOf,
  withinClick,
} from './interaction.ts'
import { sceneOf } from './scene.ts'

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

const item = (
  id: string,
  kind: BoardItem['kind'],
  x: number,
  y: number,
  w: number,
  h: number,
  parent: string | null = null,
): BoardItem => ({ id, kind, parent, x, y, w, h, text: [] })

const board: Board = {
  items: [
    item('sec', 'section', 0, 0, 400, 300),
    item('a', 'sticky', 20, 20, 100, 100, 'sec'),
    item('b', 'rect', 600, 0, 200, 100),
  ],
  connectors: [{
    id: 'c',
    from: 'a',
    to: 'b',
    style: 'straight',
    offset: 0,
    arrow: 'end',
    label: [],
  }],
}
const scene = sceneOf(board)

Deno.test('a hit prefers an item, then a connector, then the section', () => {
  assertEquals(
    (hitAt(scene, { x: 50, y: 50 }, 1) as { item: { id: string } }).item.id,
    'a',
  )
  const line = hitAt(scene, { x: 300, y: 63 }, 1)
  assertEquals(line !== null && 'connector' in line, true)
  assertEquals(
    (hitAt(scene, { x: 300, y: 250 }, 1) as { item: { id: string } }).item.id,
    'sec',
  )
  assertEquals(hitAt(scene, { x: 500, y: 250 }, 1), null)
})

Deno.test('a single selection has side and corner handles in view points', () => {
  const handles = handlesOf(scene, { items: ['a'], connector: null }, 2)
  assertEquals(handles.length, 8)
  const right = handleAt(handles, { x: 128, y: 70 }, 2)
  assertEquals(right?.kind === 'side' && right.side, 'right')
  const corner = handleAt(handles, { x: 121, y: 121 }, 2)
  assertEquals(corner?.kind === 'corner' && corner.corner, 'bottomRight')
  assertEquals(handlesOf(scene, { items: ['a', 'b'], connector: null }, 1), [])
})

Deno.test('a dropped end pins to the side whose midpoint is near', () => {
  assertEquals(targetAt(scene, { x: 605, y: 52 }, 1, 'a'), {
    id: 'b',
    side: 'left',
  })
  assertEquals(targetAt(scene, { x: 700, y: 30 }, 1, 'a'), {
    id: 'b',
    side: null,
  })
  assertEquals(targetAt(scene, { x: 50, y: 50 }, 1, 'a')?.id, 'sec')
})

Deno.test('the marquee takes a section only whole', () => {
  assertEquals(marqueeHits(scene, { x: 10, y: 10, w: 50, h: 50 }), ['a'])
  assertEquals(marqueeHits(scene, { x: -1, y: -1, w: 402, h: 302 }), [
    'sec',
    'a',
  ])
})

Deno.test('a moved section carries its child once', () => {
  const moved = movedBoard(board, ['sec', 'a'], 10, 5)
  assertEquals(moved.items.map((i) => [i.x, i.y]), [[10, 5], [20, 20], [
    600,
    0,
  ]])
  assertEquals(sectionUnder(scene, { x: 50, y: 50 }, 'a'), 'sec')
})

Deno.test('a resize keeps the opposite corner and the minimum size', () => {
  const start = { x: 0, y: 0, w: 100, h: 100 }
  assertEquals(resizedFrame(start, 'bottomRight', 20, -90), {
    x: 0,
    y: 0,
    w: 120,
    h: 24,
  })
  assertEquals(resizedFrame(start, 'topLeft', -10, 10), {
    x: -10,
    y: 10,
    w: 110,
    h: 90,
  })
})

Deno.test('an elbow wiggles on its middle segment', () => {
  assertEquals(
    wiggleOf([{ x: 0, y: 0 }, { x: 50, y: 0 }, { x: 50, y: 80 }, {
      x: 100,
      y: 80,
    }]),
    { at: { x: 50, y: 40 }, vertical: true },
  )
  assertEquals(wiggleOf([{ x: 0, y: 0 }, { x: 10, y: 10 }]), null)
})

Deno.test('the bar sits above the selection, else below, inside the view', () => {
  const view = { w: 800, h: 600 }
  const bar = { w: 200, h: 36 }
  assertEquals(barOrigin({ x: 300, y: 200, w: 100, h: 100 }, bar, view), {
    x: 250,
    y: 140,
  })
  assertEquals(barOrigin({ x: 0, y: 20, w: 100, h: 100 }, bar, view), {
    x: 8,
    y: 144,
  })
})

Deno.test('the bar keeps clear of the tool strip on the trailing edge', () => {
  const view = { w: 800, h: 600 }
  const bar = { w: 200, h: 36 }
  assertEquals(barOrigin({ x: 700, y: 200, w: 100, h: 100 }, bar, view).x, 538)
  assertEquals(
    barOrigin({ x: 0, y: 200, w: 100, h: 100 }, { w: 790, h: 36 }, view).x,
    8,
  )
})

Deno.test('a press is a click when its release lands within the slop, wherever it wandered', () => {
  const press = { x: 100, y: 100 }
  assertEquals(withinClick(press, { x: 110, y: 100 }, 1), false)
  assertEquals(withinClick(press, { x: 101, y: 100 }, 1), true)
  assertEquals(withinClick(press, { x: 103, y: 100 }, 2), false)
})
