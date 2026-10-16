import {
  isComposerSendKey,
  type SendKey,
  sendKey,
  setSendKey,
  subscribeSendKey,
} from './composer.ts'

function assertEquals<T>(actual: T, expected: T): void {
  if (actual !== expected) {
    throw new Error(`expected ${expected}, got ${actual}`)
  }
}

function sends(
  sendKey: SendKey,
  key: string,
  shiftKey: boolean,
  { isComposing = false, keyCode = key === 'Enter' ? 13 : 65 } = {},
): boolean {
  return isComposerSendKey({ key, keyCode, shiftKey, isComposing, sendKey })
}

Deno.test('composer sends only with Shift+Enter by default', () => {
  assertEquals(sends('shift-enter', 'Enter', false), false)
  assertEquals(sends('shift-enter', 'Enter', true), true)
  assertEquals(sends('shift-enter', 'a', true), false)
})

Deno.test('composer sends with Enter when the browser chose Enter', () => {
  assertEquals(sends('enter', 'Enter', false), true)
  assertEquals(sends('enter', 'Enter', true), false)
  assertEquals(sends('enter', 'a', false), false)
})

Deno.test('composer does not send while an input method is composing', () => {
  assertEquals(
    sends('shift-enter', 'Enter', true, { isComposing: true }),
    false,
  )
  assertEquals(sends('enter', 'Enter', false, { isComposing: true }), false)
})

// Safari ends composition before the keydown of the Return that accepts a
// candidate, so isComposing is false and only keyCode 229 marks it.
Deno.test('composer does not send the Return that accepts a candidate', () => {
  assertEquals(sends('enter', 'Enter', false, { keyCode: 229 }), false)
  assertEquals(sends('shift-enter', 'Enter', true, { keyCode: 229 }), false)
})

class FakeStorage {
  readonly items = new Map<string, string>()
  getItem(key: string): string | null {
    return this.items.get(key) ?? null
  }
  setItem(key: string, value: string): void {
    this.items.set(key, value)
  }
}

function withStorage(body: (storage: FakeStorage) => void): void {
  const original = Object.getOwnPropertyDescriptor(globalThis, 'localStorage')
  const storage = new FakeStorage()
  Object.defineProperty(globalThis, 'localStorage', {
    configurable: true,
    value: storage,
  })
  try {
    body(storage)
  } finally {
    if (original) Object.defineProperty(globalThis, 'localStorage', original)
  }
}

function storageEvent(key: string): Event {
  return Object.assign(new Event('storage'), { key })
}

Deno.test('the chosen send key round-trips through localStorage', () => {
  withStorage((storage) => {
    assertEquals(sendKey(), 'shift-enter')
    setSendKey('enter')
    assertEquals(storage.getItem('wuhu.composer-send-key'), 'enter')
    assertEquals(sendKey(), 'enter')
    setSendKey('shift-enter')
    assertEquals(sendKey(), 'shift-enter')
    storage.setItem('wuhu.composer-send-key', 'something-else')
    assertEquals(sendKey(), 'shift-enter')
  })
})

Deno.test('subscribers hear this tab and other tabs change the send key', () => {
  withStorage((storage) => {
    let changes = 0
    const unsubscribe = subscribeSendKey(() => changes++)
    setSendKey('enter')
    assertEquals(changes, 1)

    // Another tab writes the key; this tab hears the storage event.
    storage.setItem('wuhu.composer-send-key', 'shift-enter')
    globalThis.dispatchEvent(storageEvent('wuhu.composer-send-key'))
    assertEquals(changes, 2)
    assertEquals(sendKey(), 'shift-enter')

    globalThis.dispatchEvent(storageEvent('some-other-key'))
    assertEquals(changes, 2)

    unsubscribe()
    setSendKey('enter')
    globalThis.dispatchEvent(storageEvent('wuhu.composer-send-key'))
    assertEquals(changes, 2)
  })
})
