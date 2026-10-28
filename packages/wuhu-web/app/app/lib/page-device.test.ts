import { haptic, type HapticKind } from './shell-sdk/device.js'

const kinds: HapticKind[] = [
  'selection',
  'light',
  'medium',
  'heavy',
  'success',
  'warning',
  'error',
]

function equal(actual: unknown, expected: unknown) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${JSON.stringify(actual)} != ${JSON.stringify(expected)}`)
  }
}

function withGlobals(values: Record<string, unknown>, run: () => void) {
  const saved = new Map<string, PropertyDescriptor | undefined>()
  try {
    for (const [name, value] of Object.entries(values)) {
      saved.set(name, Object.getOwnPropertyDescriptor(globalThis, name))
      Object.defineProperty(globalThis, name, { configurable: true, value })
    }
    run()
  } finally {
    for (const [name, descriptor] of saved) {
      if (descriptor) Object.defineProperty(globalThis, name, descriptor)
      else Reflect.deleteProperty(globalThis, name)
    }
  }
}

Deno.test('haptic is a synchronous no-op without device support', () => {
  withGlobals({ webkit: undefined, navigator: {} }, () => {
    for (const kind of kinds) equal(haptic(kind), undefined)
    equal(haptic('unknown' as HapticKind), undefined)
  })
})

Deno.test('web feedback uses vibration directly, including in an iframe', () => {
  const played: unknown[] = []
  withGlobals({
    webkit: undefined,
    navigator: { vibrate: (pattern: unknown) => played.push(pattern) },
  }, () => {
    for (const kind of kinds) haptic(kind)
    haptic('unknown' as HapticKind)
    haptic('toString' as HapticKind)
    equal(played, [5, 10, 20, 30, [10, 40, 10], [20, 40, 20], [
      30,
      40,
      30,
      40,
      30,
    ]])
  })
})

Deno.test('native feedback posts typed messages without also vibrating', () => {
  const posted: unknown[] = []
  withGlobals({
    webkit: {
      messageHandlers: {
        wuhuShell: { postMessage: (value: unknown) => posted.push(value) },
      },
    },
    navigator: {
      vibrate: () => {
        throw new Error('native must not vibrate')
      },
    },
  }, () => {
    for (const kind of kinds) haptic(kind)
    haptic('unknown' as HapticKind)
    equal(posted, kinds.map((kind) => ({ type: 'wuhu:haptic', kind })))
  })
})

Deno.test('feedback never throws when the host refuses it', () => {
  for (const native of [true, false]) {
    const refuse = () => {
      throw new Error('unsupported')
    }
    withGlobals({
      webkit: native
        ? { messageHandlers: { wuhuShell: { postMessage: refuse } } }
        : undefined,
      navigator: { vibrate: refuse },
    }, () => equal(haptic('error'), undefined))
  }
})

Deno.test('unknown kinds log the valid kinds without playing feedback', () => {
  const errors: string[] = []
  const played: unknown[] = []
  withGlobals({
    console: { error: (message: string) => errors.push(message) },
    webkit: undefined,
    navigator: { vibrate: (pattern: unknown) => played.push(pattern) },
  }, () => {
    equal(haptic('unknown' as HapticKind), undefined)
    equal(played, [])
    equal(errors, [
      'Unknown haptic kind unknown. Valid kinds: ' + kinds.join(', '),
    ])
  })
})
