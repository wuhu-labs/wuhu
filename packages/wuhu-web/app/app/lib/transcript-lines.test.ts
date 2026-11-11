import { assertEquals } from 'jsr:@std/assert@1'
import vectors from './session-line.vectors.json' with { type: 'json' }
import type { SessionLineEvent, SessionLinePayload } from './contract.gen.ts'
import {
  foldLines,
  hasContent,
  initialLines,
  lineView,
} from './transcript-lines.ts'

function line(position: number, key = `k${position}`): SessionLinePayload {
  return {
    position,
    at: 0,
    role: 'user',
    key,
    prompt: false,
    message: { user: { content: [{ text: { text: key } }] } },
  }
}

function fold(events: SessionLineEvent[]) {
  return events.reduce(foldLines, initialLines)
}

Deno.test('lines land at their positions, a late prompt line before what came first', () => {
  const state = fold([
    { kind: 'reset', generation: 2 },
    { kind: 'line', generation: 2, line: line(3) },
    { kind: 'line', generation: 2, line: line(4) },
    { kind: 'line', generation: 2, line: line(0, 'system') },
    { kind: 'line', generation: 2, line: line(1, 'group') },
  ])
  assertEquals(state.lines.map((line) => line.key), [
    'system',
    'group',
    'k3',
    'k4',
  ])
})

Deno.test('a resent line replaces the one at its position, another generation is dropped, and a reset clears', () => {
  const held = fold([
    { kind: 'reset', generation: 1 },
    { kind: 'line', generation: 1, line: line(0, 'system') },
    { kind: 'line', generation: 1, line: line(3) },
    { kind: 'line', generation: 1, line: line(0, 'system') },
    { kind: 'line', generation: 0, line: line(9) },
  ])
  assertEquals(held.lines.map((line) => line.position), [0, 3])
  assertEquals(foldLines(held, { kind: 'reset', generation: 2 }), {
    generation: 2,
    lines: [],
  })
})

// The server encodes these lines from real transcript records
// (SessionLineVectorTests); the web reads them back.
Deno.test('a line view reads the server line vectors', () => {
  const views = Object.fromEntries(
    (vectors as { name: string; line: SessionLinePayload }[]).map((
      vector,
    ) => [vector.name, lineView(vector.line)]),
  )
  assertEquals(views['system']!.rendered, '0f3a')
  assertEquals(hasContent(views['system']!), true)
  assertEquals(views['group instructions']!.blocks, [
    { kind: 'text', text: 'Be brief.' },
  ])
  assertEquals(views['user text']!.blocks, [{ kind: 'text', text: 'hello' }])
  assertEquals(views['assistant reasoning, text and a tool call']!.blocks, [
    { kind: 'reasoning', text: 'thinking it over' },
    { kind: 'reasoning', text: 'plain thought' },
    { kind: 'text', text: 'Reading it.' },
    { kind: 'toolCall', name: 'read', arguments: '{"path":"/a.md"}' },
  ])
  assertEquals(views['failed tool result']!.failed, true)
  assertEquals(views['failed tool result']!.blocks, [
    { kind: 'text', text: 'no such file' },
  ])
  assertEquals(views['inline image']!.blocks, [
    { kind: 'text', text: '[inline image image/png, 30 bytes as a data URL]' },
  ])
  assertEquals(views['hosted web search']!.blocks, [
    { kind: 'hostedTool', type: 'web_search_call' },
  ])
  assertEquals(views['linked image']!.blocks, [
    { kind: 'media', mimeType: 'image/jpeg' },
  ])
  assertEquals(views['user text']!.at.getTime(), 1_791_000_003_000)
  assertEquals(hasContent(lineView(line(1, ' '))), false)
})
