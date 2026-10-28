const patterns = new Map([
  ['selection', 5],
  ['light', 10],
  ['medium', 20],
  ['heavy', 30],
  ['success', [10, 40, 10]],
  ['warning', [20, 40, 20]],
  ['error', [30, 40, 30, 40, 30]],
])

export function haptic(kind) {
  try {
    if (!patterns.has(kind)) {
      console.error(
        'Unknown haptic kind ' + String(kind) + '. Valid kinds: ' +
          [...patterns.keys()].join(', '),
      )
      return
    }
    const native = globalThis.webkit?.messageHandlers?.wuhuShell
    if (native) {
      native.postMessage({ type: 'wuhu:haptic', kind })
    } else {
      globalThis.navigator?.vibrate?.(patterns.get(kind))
    }
  } catch {
    // Feedback is best-effort, including when a browser refuses vibration.
  }
}
