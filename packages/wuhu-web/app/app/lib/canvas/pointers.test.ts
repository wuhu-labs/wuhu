import { PointerRouter } from './pointers.ts'

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

function recorded(claims: boolean) {
  const log: string[] = []
  const router = new PointerRouter({
    claim: (at) => (log.push(`claim ${at.x},${at.y}`), claims),
    edit: (at) => log.push(`edit ${at.x},${at.y}`),
    release: (at, cancelled) =>
      log.push(`release ${at.x},${at.y}${cancelled ? ' cancelled' : ''}`),
    pan: (dx, dy) => log.push(`pan ${dx},${dy}`),
    pinch: (mid, dx, dy, ratio) =>
      log.push(`pinch ${mid.x},${mid.y} ${dx},${dy} x${ratio}`),
  })
  return { router, log }
}

Deno.test('a claimed pointer edits and releases', () => {
  const { router, log } = recorded(true)
  assertEquals(router.down(1, { x: 10, y: 10 }), true)
  router.move(1, { x: 20, y: 10 })
  router.up(1, { x: 20, y: 10 }, false)
  assertEquals(log, ['claim 10,10', 'edit 20,10', 'release 20,10'])
})

Deno.test('an unclaimed pointer pans, two pinch', () => {
  const { router, log } = recorded(false)
  router.down(1, { x: 0, y: 0 })
  router.move(1, { x: 5, y: 0 })
  router.down(2, { x: 25, y: 0 })
  router.move(2, { x: 45, y: 0 })
  assertEquals(log, ['claim 0,0', 'pan 5,0', 'pinch 25,0 10,0 x2'])
})

Deno.test('a second finger cancels the edit and pinches from where the first one is', () => {
  const { router, log } = recorded(true)
  router.down(1, { x: 10, y: 10 })
  router.move(1, { x: 12, y: 10 })
  assertEquals(router.down(2, { x: 32, y: 10 }), true)
  assertEquals(router.pinching, true)
  router.move(2, { x: 52, y: 10 })
  router.move(1, { x: 2, y: 10 })
  router.up(1, { x: 2, y: 10 }, false)
  router.up(2, { x: 52, y: 10 }, false)
  assertEquals(log, [
    'claim 10,10',
    'edit 12,10',
    'release 12,10 cancelled',
    'pinch 32,10 10,0 x2',
    'pinch 27,10 -5,0 x1.25',
  ])
})
