import vectors from './viewing.vectors.json' with { type: 'json' }
import { viewingSpelling } from './viewing.ts'

function equal(actual: unknown, expected: unknown) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    )
  }
}

// The shared fixture (wuhu-core SpaceContract/Tests/contract), which the
// server's own test holds to what it stores and refuses.
Deno.test('a shown path is named group-qualified', () => {
  for (const { group, path, viewing } of vectors.named.cases) {
    equal([path, viewingSpelling(group, path)], [path, viewing])
  }
})

Deno.test('the root names no page', () => {
  for (const { group, path } of vectors.unnamed.cases) {
    equal([path, viewingSpelling(group, path)], [path, null])
  }
})

Deno.test('what the server would refuse is omitted', () => {
  for (const path of vectors.omitted.paths) {
    equal([path, viewingSpelling('shared', path)], [path, null])
  }
})

// A send only builds a spelling from a space path, never from a relative or
// system one; the server never sees these.
Deno.test('a path that is not a space path is omitted', () => {
  for (const path of ['notes/plan.md', 'wuhu://system/AGENTS.md']) {
    equal([path, viewingSpelling('shared', path)], [path, null])
  }
})

Deno.test('a path in an invalid group is omitted', () => {
  for (const group of ['', 'Shared', '-shared', 'sh.ared']) {
    equal([group, viewingSpelling(group, '/plan.md')], [group, null])
  }
})

Deno.test('the spelling is at most 1024 bytes', () => {
  const prefix = 'wuhu://shared.localspace/'.length
  const fits = '/' + 'a'.repeat(1024 - prefix)
  equal(viewingSpelling('shared', fits)?.length, 1024)
  equal(viewingSpelling('shared', fits + 'a'), null)
  const wide = '/' + '日'.repeat(Math.floor((1024 - prefix) / 3) + 1)
  equal(viewingSpelling('shared', wide), null)
})
