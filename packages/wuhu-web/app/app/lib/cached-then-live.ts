// Paints the kept value first, if there is one, then the live one. A live
// failure after a kept paint leaves the paint standing; one without a paint
// is reported, once the kept lookup has settled.
export function cachedThenLive<Value>(
  cached: () => Promise<Value>,
  live: () => Promise<Value>,
  paint: (value: Value) => void,
  fail: (failure: unknown) => void,
): void {
  let painted = false
  let fresh = false
  const first = cached().then(
    (value) => {
      if (fresh) return
      painted = true
      paint(value)
    },
    () => undefined,
  )
  live().then(
    (value) => {
      fresh = true
      paint(value)
    },
    (failure: unknown) =>
      first.then(() => {
        if (!painted) fail(failure)
      }),
  )
}

// A kept lookup that finds nothing paints nothing.
export async function kept<Value>(
  lookup: Promise<Value | undefined> | undefined,
): Promise<Value> {
  const value = await lookup
  if (value === undefined) throw new Error('nothing kept')
  return value
}
