import { newDocumentPath } from './new-document.ts'

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

const none = () => false

Deno.test('appends .md when the name has no extension', () => {
  assertEquals(newDocumentPath('/notes', 'ideas', none), {
    path: '/notes/ideas.md',
  })
})

Deno.test('keeps an explicit extension', () => {
  assertEquals(newDocumentPath('/notes', 'ideas.markdown', none), {
    path: '/notes/ideas.markdown',
  })
})

Deno.test('creates at the root without doubling the slash', () => {
  assertEquals(newDocumentPath('/', 'readme', none), { path: '/readme.md' })
})

Deno.test('trims and refuses empty, slashed, and dot names', () => {
  assertEquals('error' in newDocumentPath('/notes', '   ', none), true)
  assertEquals('error' in newDocumentPath('/notes', 'a/b', none), true)
  assertEquals('error' in newDocumentPath('/notes', '..', none), true)
})

Deno.test('refuses a path that already exists', () => {
  const result = newDocumentPath(
    '/notes',
    'ideas',
    (p) => p === '/notes/ideas.md',
  )
  assertEquals(result, { error: '/notes/ideas.md already exists.' })
})
