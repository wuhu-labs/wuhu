import {
  contentMessage,
  shellContext,
  totalInsets,
  zeroInsets,
} from './shell.ts'

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

Deno.test('contentMessage accepts only exact shell protocol messages', () => {
  assertEquals(contentMessage({ type: 'wuhu:ready' }), {
    type: 'wuhu:ready',
  })
  assertEquals(contentMessage({ type: 'wuhu:navigate', path: '/a?q=1#b' }), {
    type: 'wuhu:navigate',
    path: '/a?q=1#b',
  })
  assertEquals(contentMessage({ type: 'wuhu:unauthorized' }), {
    type: 'wuhu:unauthorized',
  })
  assertEquals(contentMessage({ type: 'wuhu:ready', path: '/extra' }), null)
  assertEquals(
    contentMessage({ type: 'wuhu:navigate', path: 'relative' }),
    null,
  )
  assertEquals(
    contentMessage({ type: 'wuhu:navigate', path: '//other.test' }),
    null,
  )
  assertEquals(contentMessage({ type: 'wuhu:navigate', path: '/a\n' }), null)
  assertEquals(
    contentMessage({ type: 'wuhu:navigate', path: '/../sessions' }),
    null,
  )
  assertEquals(contentMessage(['wuhu:ready']), null)
})

Deno.test('shell context names the viewer a member and carries zero insets', () => {
  assertEquals(zeroInsets, { top: 0, left: 0, right: 0, bottom: 0 })
  assertEquals(shellContext('https://shell.test', zeroInsets), {
    type: 'wuhu:context',
    mode: 'shell',
    access: 'member',
    shellOrigin: 'https://shell.test',
    insets: zeroInsets,
  })
})

Deno.test('host sends device safe area plus chrome on all four edges', () => {
  const insets = totalInsets(
    { top: 59, left: 7, right: 11, bottom: 34 },
    { top: 52, left: 280, right: 13, bottom: 74 },
  )
  assertEquals(shellContext('https://shell.test', insets).insets, {
    top: 111,
    left: 287,
    right: 24,
    bottom: 108,
  })
  assertEquals(totalInsets(insets, zeroInsets), insets)
})
