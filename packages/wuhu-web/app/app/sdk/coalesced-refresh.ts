export function coalescedRefresh<Value>(
  load: () => Promise<Value>,
  receive: (value: Value) => void,
  failed: (failure: unknown) => void,
) {
  let closed = false
  let pending = false
  let running: Promise<void> | undefined
  const run = (): Promise<void> => {
    if (closed) return Promise.resolve()
    if (running) {
      pending = true
      return running
    }
    running = Promise.resolve().then(load).then(
      (value) => {
        if (!closed) receive(value)
      },
      (failure) => {
        if (!closed) failed(failure)
      },
    ).finally(() => {
      running = undefined
      if (pending) {
        pending = false
        void run()
      }
    })
    return running
  }
  return {
    run,
    close: () => {
      closed = true
    },
  }
}
