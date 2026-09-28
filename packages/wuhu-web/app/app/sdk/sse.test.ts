import { sseParser } from '~/lib/shell-sdk/open-cache.js'

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

const message = (data: string) => ({ event: 'message', data })

Deno.test('a complete event yields its data', () => {
  const parser = sseParser()
  assertEquals(parser.push('data: {"n":1}\n\n'), [message('{"n":1}')])
})

Deno.test('events split across chunks are buffered', () => {
  const parser = sseParser()
  assertEquals(parser.push('data: par'), [])
  assertEquals(parser.push('tial\n'), [])
  assertEquals(parser.push('\ndata: next\n\n'), [
    message('partial'),
    message('next'),
  ])
})

Deno.test('CRLF framing and multi-line data are normalized', () => {
  const parser = sseParser()
  assertEquals(parser.push('data: a\r\ndata: b\r\n\r\n'), [message('a\nb')])
})

Deno.test('comments and records without data carry no payload; a named event keeps its name', () => {
  const parser = sseParser()
  assertEquals(parser.push(': keepalive\n\nevent: tick\nid: 4\n\n'), [])
  assertEquals(parser.push('event: tick\ndata: x\n\n'), [
    { event: 'tick', data: 'x' },
  ])
})
