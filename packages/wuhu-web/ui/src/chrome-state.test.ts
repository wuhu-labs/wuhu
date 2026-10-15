/// <reference lib="deno.ns" />
import { chromeState, stepChrome } from './chrome-state.ts'

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

Deno.test('crossing the compact threshold flips compact and mode in one step', () => {
  const wide = stepChrome(chromeState(false, 'full'), {
    kind: 'peek',
    peek: true,
  })
  assertEquals(stepChrome(wide, { kind: 'compact', compact: true }), {
    compact: true,
    mode: 'focus',
    peek: false,
  })
  const narrow = chromeState(true, 'full')
  assertEquals(stepChrome(narrow, { kind: 'compact', compact: false }), {
    compact: false,
    mode: 'full',
    peek: false,
  })
})

Deno.test('a change event that keeps the threshold keeps the chrome', () => {
  const focused = stepChrome(chromeState(false, 'full'), {
    kind: 'mode',
    mode: 'focus',
  })
  if (stepChrome(focused, { kind: 'compact', compact: false }) !== focused) {
    throw new Error('the same compact value replaced the chrome')
  }
})

Deno.test('shortcuts and mode changes close the peek', () => {
  const peeking = stepChrome(
    stepChrome(chromeState(false, 'focus'), { kind: 'peek', peek: true }),
    { kind: 'peek', peek: true },
  )
  assertEquals(peeking, { compact: false, mode: 'focus', peek: true })
  assertEquals(stepChrome(peeking, { kind: 'escape' }), {
    compact: false,
    mode: 'full',
    peek: false,
  })
  assertEquals(stepChrome(peeking, { kind: 'toggle' }), {
    compact: false,
    mode: 'full',
    peek: false,
  })
  assertEquals(stepChrome(peeking, { kind: 'mode', mode: 'focus' }), {
    compact: false,
    mode: 'focus',
    peek: false,
  })
})

Deno.test('an escape or mode change that changes nothing keeps the chrome', () => {
  const full = chromeState(false, 'full')
  if (stepChrome(full, { kind: 'escape' }) !== full) {
    throw new Error('escape in full mode replaced the chrome')
  }
  if (stepChrome(full, { kind: 'mode', mode: 'full' }) !== full) {
    throw new Error('the same mode replaced the chrome')
  }
  const focused = chromeState(true, 'full')
  if (stepChrome(focused, { kind: 'mode', mode: 'focus' }) !== focused) {
    throw new Error('the same mode replaced the focused chrome')
  }
})
