import {
  isNotFound,
  ownBriefPath,
  previewLines,
  sizeLabel,
  splitChain,
} from './session-context.ts'
import { ApiError } from '~/sdk/errors'

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

const home = '/sessions/abc'

Deno.test('splits the chain, keeping ancestors in injection order', () => {
  assertEquals(
    splitChain(
      ['/AGENTS.md', '/sessions/root/AGENTS.md', ownBriefPath(home)],
      home,
    ),
    {
      ancestors: ['/AGENTS.md', '/sessions/root/AGENTS.md'],
      own: ownBriefPath(home),
    },
  )
})

Deno.test('names the own slot even when the chain omits it', () => {
  assertEquals(splitChain(['/AGENTS.md'], home), {
    ancestors: ['/AGENTS.md'],
    own: '/sessions/abc/AGENTS.md',
  })
})

Deno.test('an empty chain still yields the own slot', () => {
  assertEquals(splitChain([], home), {
    ancestors: [],
    own: '/sessions/abc/AGENTS.md',
  })
})

Deno.test('previews the first lines and reports truncation', () => {
  const content = ['a', 'b', 'c', 'd', 'e', 'f', 'g'].join('\n')
  assertEquals(previewLines(content, 6), {
    text: 'a\nb\nc\nd\ne\nf',
    truncated: true,
  })
})

Deno.test('a short document is not truncated', () => {
  assertEquals(previewLines('a\nb', 6), { text: 'a\nb', truncated: false })
})

Deno.test('trailing blank lines do not count as more content', () => {
  const content = 'a\nb\nc\nd\ne\nf\n\n   \n'
  assertEquals(previewLines(content, 6), { text: content, truncated: false })
})

Deno.test('notFound is recognised by status and by code', () => {
  assertEquals(
    isNotFound(new ApiError(404, { code: 'internal', message: 'gone' })),
    true,
  )
  assertEquals(
    isNotFound(new ApiError(400, { code: 'notFound', message: 'gone' })),
    true,
  )
  assertEquals(
    isNotFound(new ApiError(500, { code: 'internal', message: 'boom' })),
    false,
  )
  assertEquals(isNotFound(new Error('offline')), false)
})

Deno.test('sizes read in bytes, kilobytes and megabytes', () => {
  assertEquals(sizeLabel(0), '0 B')
  assertEquals(sizeLabel(1023), '1023 B')
  assertEquals(sizeLabel(2048), '2 KB')
  assertEquals(sizeLabel(3 * 1024 * 1024), '3.0 MB')
})
