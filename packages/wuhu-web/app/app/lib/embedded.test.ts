import { isEmbeddedHost } from './embedded.ts'

function assertEquals(actual: boolean, expected: boolean) {
  if (actual !== expected) {
    throw new Error(`expected ${expected}, got ${actual}`)
  }
}

Deno.test('the dedicated native signal is detected synchronously in the top frame', () => {
  const host = {
    webkit: { messageHandlers: { wuhuEmbedded: { postMessage() {} } } },
  }
  assertEquals(isEmbeddedHost({ ...host, top: host }), false)
  assertEquals(isEmbeddedHost(Object.assign(host, { top: host })), true)
})

Deno.test('a child frame ignores the native signal even when WebKit exposes it', () => {
  const handlers = { wuhuEmbedded: { postMessage() {} } }
  const top = { webkit: { messageHandlers: handlers } }
  const child = { top, webkit: { messageHandlers: handlers } }
  assertEquals(isEmbeddedHost(child), false)
})

Deno.test('browsers, older apps and malformed signals retain normal chrome', () => {
  for (
    const host of [
      {},
      { webkit: {} },
      { webkit: { messageHandlers: {} } },
      { webkit: { messageHandlers: { wuhuEmbedded: {} } } },
      { webkit: { messageHandlers: { wuhuEmbedded: { postMessage: true } } } },
      { webkit: { messageHandlers: { wuhuShell: { postMessage() {} } } } },
    ]
  ) {
    assertEquals(isEmbeddedHost(Object.assign(host, { top: host })), false)
  }
})
