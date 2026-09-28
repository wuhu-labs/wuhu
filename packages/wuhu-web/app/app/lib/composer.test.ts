import { isComposerSendKey } from './composer.ts'

function assertEquals(actual: boolean, expected: boolean): void {
  if (actual !== expected) {
    throw new Error(`expected ${expected}, got ${actual}`)
  }
}

Deno.test('composer sends only with Shift+Enter', () => {
  assertEquals(
    isComposerSendKey({ key: 'Enter', shiftKey: false, isComposing: false }),
    false,
  )
  assertEquals(
    isComposerSendKey({ key: 'Enter', shiftKey: true, isComposing: false }),
    true,
  )
  assertEquals(
    isComposerSendKey({ key: 'a', shiftKey: true, isComposing: false }),
    false,
  )
})

Deno.test('composer does not send while an input method is composing', () => {
  assertEquals(
    isComposerSendKey({ key: 'Enter', shiftKey: true, isComposing: true }),
    false,
  )
})
