import { assertEquals, assertMatch, assertThrows } from '@std/assert'
import { compileJSX } from '../src/compile.ts'

Deno.test('elements become h calls and the module stays a module', () => {
  const code = compileJSX(
    [
      "export const sizes = ['small', 'wide']",
      'export default async function ({ size }) {',
      '  const [{ n }] = await query`SELECT 1 AS n`',
      '  return <Figure value={n} label="One">{size}<>x</></Figure>',
      '}',
    ].join('\n'),
    '/.widgets/one.widget.jsx',
  )
  assertMatch(code, /export const sizes = \['small', 'wide'\]/)
  assertMatch(code, /export default async function/)
  assertMatch(
    code,
    /h\(Figure, \{ value: n, label: "One",\}, size, h\(Fragment, null, "x"\)\)/,
  )
})

Deno.test('a syntax error names its line and column', () => {
  const error = assertThrows(() =>
    compileJSX('export default () => <Figure value=>', '/bad.jsx')
  )
  assertEquals(error instanceof Error, true)
  assertMatch((error as Error).message, /\(1:\d+\)/)
})
