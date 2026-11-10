import { connectorPaths, rounded } from './connector-path.ts'

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

const stroke = { color: '#D8DAE5FF', width: 3.2 }

Deno.test('an arrowhead is an open chevron whose tip stops half a line short of the end', () => {
  assertEquals(
    connectorPaths({
      points: [{ x: 0, y: 0 }, { x: 100, y: 0 }],
      arrow: 'end',
      stroke,
    }),
    { line: 'M0,0L98.4,0', heads: 'M90.9,6.125L98.4,0L90.9,-6.125' },
  )
  assertEquals(
    connectorPaths({
      points: [{ x: 0, y: 0 }, { x: 0, y: 100 }],
      arrow: 'both',
      stroke,
    }),
    {
      line: 'M0,1.6L0,98.4',
      heads: 'M-6.125,90.9L0,98.4L6.125,90.9M6.125,9.1L0,1.6L-6.125,9.1',
    },
  )
  assertEquals(
    connectorPaths({
      points: [{ x: 0, y: 0 }, { x: 100, y: 0 }],
      arrow: 'none',
      stroke,
    }),
    { line: 'M0,0L100,0', heads: '' },
  )
})

Deno.test('a bend is an arc of 20, less where a leg cannot hold it', () => {
  const elbow = rounded([
    { x: 0, y: 0 },
    { x: 100, y: 0 },
    { x: 100, y: 100 },
    { x: 200, y: 100 },
  ])
  assertEquals(
    elbow.match(/[ML][^MLC]+|C[^MLC]+/g)?.filter((part) =>
      !part.startsWith('C')
    ),
    ['M0,0', 'L80,0', 'L100,80', 'L200,100'],
  )
  assertEquals(elbow.match(/ (\S+)(?=L)/g), [' 100,20', ' 120,100'])
  assertEquals(
    rounded([{ x: 0, y: 0 }, { x: 10, y: 0 }, { x: 10, y: 100 }]),
    'M0,0L0,0C5.523,0 10,4.477 10,10L10,100',
  )
})
