import vectors from './space-url.vectors.json' with { type: 'json' }
import {
  formatSpaceURL,
  parseSpaceURL,
  spaceDestination,
  spaceHost,
} from './space-url.ts'

function assertEquals(actual: unknown, expected: unknown, label = ''): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`${label}: expected ${e}, got ${a}`)
}

Deno.test('accepted spellings parse and format both schemes', () => {
  for (
    const vector of [...vectors.accepted, ...vectors.contextual] as Array<
      (typeof vectors.accepted)[number] & { contextHost?: string }
    >
  ) {
    const url = parseSpaceURL(vector.spelling, vector.contextHost)
    if (url == null) throw new Error(`rejected ${vector.spelling}`)
    assertEquals(url.host, vector.host, vector.spelling)
    assertEquals(url.destination, vector.destination, vector.spelling)
    assertEquals(url.query, 'query' in vector ? vector.query : undefined)
    assertEquals(
      url.fragment,
      'fragment' in vector ? vector.fragment : undefined,
    )
    assertEquals(formatSpaceURL(url, 'https'), vector.https)
    assertEquals(formatSpaceURL(url, 'wuhu'), vector.wuhu)
    assertEquals(parseSpaceURL(vector.https), url)
    assertEquals(parseSpaceURL(vector.wuhu), url)
  }
})

Deno.test('malformed and removed spellings are rejected', () => {
  for (const spelling of vectors.rejected) {
    assertEquals(parseSpaceURL(spelling), null, spelling)
  }
})

Deno.test('a hostless link needs the host of the space it lives in', () => {
  for (const vector of vectors.contextual) {
    if (!vector.spelling.includes('://')) {
      assertEquals(parseSpaceURL(vector.spelling), null, vector.spelling)
    }
  }
  for (const vector of vectors.contextualRejected) {
    assertEquals(
      parseSpaceURL(vector.spelling, vector.contextHost),
      null,
      vector.spelling,
    )
  }
})

Deno.test('an origin names its host', () => {
  for (const vector of vectors.origins) {
    assertEquals(spaceHost(vector.origin), vector.host, vector.origin)
  }
})

Deno.test('destinations resolve from a plain path', () => {
  assertEquals(spaceDestination('/_/conversations/c1'), {
    kind: 'conversation',
    id: 'c1',
  })
  assertEquals(spaceDestination('/a%20b.md'), { kind: 'path', path: '/a b.md' })
  assertEquals(spaceDestination('a.md'), null)
})
