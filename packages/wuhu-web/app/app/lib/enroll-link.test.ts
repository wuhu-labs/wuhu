import {
  enrollHash,
  parseEnrollFragment,
  parsePastedEnrollLink,
} from './enroll-link.ts'

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

const space = 'spc_' + 'a1'.repeat(16)
const link = { token: 'jt_secret', space }

Deno.test('parseEnrollFragment demands token and a well-formed space id', () => {
  assertEquals(parseEnrollFragment(`#token=jt_secret&space=${space}`), link)
  assertEquals(parseEnrollFragment(`token=jt_secret&space=${space}`), link)
  assertEquals(parseEnrollFragment('#token=jt_secret'), null)
  assertEquals(parseEnrollFragment(`#space=${space}`), null)
  assertEquals(parseEnrollFragment('#token=jt_secret&space=spc_short'), null)
  assertEquals(parseEnrollFragment(''), null)
})

Deno.test('parsePastedEnrollLink accepts full links and bare fragments', () => {
  assertEquals(
    parsePastedEnrollLink(
      `  https://origin.test:5530/_/enroll#token=jt_secret&space=${space}\n`,
    ),
    link,
  )
  assertEquals(
    parsePastedEnrollLink(`#token=jt_secret&space=${space}`),
    link,
  )
  assertEquals(
    parsePastedEnrollLink(`token=jt_secret&space=${space}`),
    link,
  )
  assertEquals(parsePastedEnrollLink('https://origin.test/_/enroll'), null)
  assertEquals(parsePastedEnrollLink('not a link'), null)
  assertEquals(parsePastedEnrollLink(''), null)
})

Deno.test('enrollHash round-trips through parseEnrollFragment', () => {
  assertEquals(parseEnrollFragment(enrollHash(link)), link)
  const awkward = { token: 'jt_+&= x', space }
  assertEquals(parseEnrollFragment(enrollHash(awkward)), awkward)
})
