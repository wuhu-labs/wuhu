import { callout, mentions } from './editor-marks.ts'

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

Deno.test('callout recognises the five GitHub kinds, case-insensitively', () => {
  assertEquals(callout('[!NOTE] hello'), {
    kind: 'note',
    title: 'Note',
    markerLength: 8,
  })
  assertEquals(callout('[!warning]'), {
    kind: 'warning',
    title: 'Warning',
    markerLength: 10,
  })
  assertEquals(callout('[!TODO] hello'), null)
  assertEquals(callout('plain [!NOTE]'), null)
})

Deno.test('mentions find @handles at word starts and skip emails', () => {
  assertEquals(mentions('ping @alice and (@bob.smith) but not a@b'), [
    { from: 5, to: 11 },
    { from: 17, to: 27 },
  ])
  assertEquals(mentions('@x'), [{ from: 0, to: 2 }])
  assertEquals(mentions('no handles'), [])
})
