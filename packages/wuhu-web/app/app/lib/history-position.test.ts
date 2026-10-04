import { assertEquals } from 'jsr:@std/assert@1'
import { historyPosition, restoredHistoryTop } from './history-position.ts'

Deno.test('Back restores the visible durable item and focus after detail-time prepend', () => {
  const before = [
    { id: '7:20:0', top: 60, bottom: 136 },
    { id: '7:21:0', top: 136, bottom: 212 },
  ]
  const saved = historyPosition(500, 100, before, '7:21:0')
  assertEquals(saved.anchor, { id: '7:20:0', offset: -40 })
  const after = [
    { id: '7:1:0', top: 100, bottom: 176 },
    ...before.map((row) => ({
      ...row,
      top: row.top + 1000,
      bottom: row.bottom + 1000,
    })),
  ]
  assertEquals(restoredHistoryTop(saved, 0, 100, after), 1000)
  assertEquals(saved.focus, '7:21:0')
})

Deno.test('live history updates retain the same source offset instead of numeric scrollTop', () => {
  const saved = historyPosition(500, 100, [
    { id: 'visible', top: 80, bottom: 156 },
  ], 'selected')
  assertEquals(
    restoredHistoryTop(saved, 500, 100, [
      { id: 'visible', top: 840, bottom: 916 },
    ]),
    1260,
  )
  assertEquals(restoredHistoryTop(saved, 500, 100, []), 500)
})
