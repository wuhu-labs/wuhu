import { assertEquals } from 'jsr:@std/assert@1'
import { keyboardViewport } from './keyboard-viewport.ts'

Deno.test('text entry uses the unobscured visual viewport above the keyboard', () => {
  assertEquals(
    keyboardViewport({
      baselineHeight: 844,
      height: 477,
      offsetTop: 182,
      scale: 1,
      textEntryFocused: true,
    }),
    { height: 477, offsetTop: 182 },
  )
})

Deno.test('ordinary viewport changes do not activate keyboard compensation', () => {
  assertEquals(
    keyboardViewport({
      baselineHeight: 844,
      height: 780,
      offsetTop: 0,
      scale: 1,
      textEntryFocused: true,
    }),
    null,
  )
  assertEquals(
    keyboardViewport({
      baselineHeight: 844,
      height: 477,
      offsetTop: 182,
      scale: 1,
      textEntryFocused: false,
    }),
    null,
  )
  assertEquals(
    keyboardViewport({
      baselineHeight: 844,
      height: 477,
      offsetTop: 182,
      scale: 2,
      textEntryFocused: true,
    }),
    null,
  )
})
