import { assertEquals } from 'jsr:@std/assert@1'
import { OlderIntent } from './history-intent.ts'

Deno.test('layout and one continuous upward wheel gesture cannot cascade pages', () => {
  const intent = new OlderIntent()
  intent.moved(0)
  intent.wheel(100)
  assertEquals(intent.approach(0, true), true)
  intent.wheel(130)
  assertEquals(intent.approach(0, false), false)
  intent.wheel(160)
  assertEquals(intent.approach(0, true), false)
  intent.wheel(500)
  assertEquals(intent.approach(0, true), true)
})

Deno.test('new touch/key intent and leaving the history edge permit one next page', () => {
  const intent = new OlderIntent()
  assertEquals(intent.approach(200, true), false)
  assertEquals(intent.approach(0, true), true)
  assertEquals(intent.approach(0, true), false)
  intent.moved(200)
  assertEquals(intent.approach(0, true), true)
  intent.begin()
  assertEquals(intent.approach(0, true), true)
})
