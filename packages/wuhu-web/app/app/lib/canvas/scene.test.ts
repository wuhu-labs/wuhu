import type { BoardConnector, ItemKind } from './board.ts'
import { endsOf, type Rect } from './scene.ts'

// RoutingTests in CanvasScene hold the Swift routing to the same cases.

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

const connector = (
  id: string,
  from: string,
  to: string,
  fromSide?: BoardConnector['fromSide'],
): BoardConnector => ({
  id,
  from,
  to,
  ...(fromSide === undefined ? {} : { fromSide }),
  style: 'straight',
  offset: 0,
  arrow: 'end',
  label: [],
})

Deno.test('ends sharing a short side spread over most of it in the order of what they lead to', () => {
  const targets: [string, number][] = [['far', 300], ['top', -200], [
    'mid',
    20,
  ]]
  const frames = new Map<string, Rect>([['hub', { x: 0, y: 0, w: 100, h: 40 }]])
  for (const [id, y] of targets) {
    frames.set(id, { x: 400, y: y - 20, w: 40, h: 40 })
  }
  const ends = endsOf(
    targets.map(([id], i) => connector(`c${i}`, 'hub', id, 'right')),
    frames,
    new Map<string, ItemKind>([['hub', 'diamond']]),
  )
  assertEquals(ends.map(([, from]) => from.point), [
    { x: 60, y: 36 },
    { x: 60, y: 4 },
    { x: 100, y: 20 },
  ])
  assertEquals(ends.map(([, , to]) => to.side), ['left', 'left', 'left'])
})

Deno.test('a free end takes the other facing side only when it is open', () => {
  const frames = new Map<string, Rect>([
    ['hub', { x: 0, y: 0, w: 100, h: 100 }],
    ['right', { x: 300, y: 0, w: 100, h: 100 }],
    ['low', { x: 300, y: 300, w: 100, h: 100 }],
  ])
  const pinned = connector('c1', 'hub', 'right', 'right')
  const free = connector('c2', 'hub', 'low')
  const sides = (connectors: BoardConnector[]) =>
    endsOf(connectors, frames, new Map()).map(([, from]) => from.side)
  assertEquals(sides([free, pinned]), ['bottom', 'right'])
  const bottom = connector('c3', 'hub', 'low', 'bottom')
  assertEquals(sides([free, pinned, bottom]), ['right', 'right', 'bottom'])
})
