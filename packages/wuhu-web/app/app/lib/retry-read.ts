export interface RetryClock {
  after(milliseconds: number, callback: () => void): () => void
}

export const retryClock: RetryClock = {
  after(milliseconds, callback) {
    const timer = setTimeout(callback, milliseconds)
    return () => clearTimeout(timer)
  },
}

export function retryRead<Value>(
  read: () => Promise<Value>,
  receive: (value: Value) => void,
  failed: (error: unknown) => void,
  clock: RetryClock = retryClock,
): () => void {
  let closed = false
  let delay = 1000
  let cancel = () => {}
  const attempt = () => {
    void read().then((value) => {
      if (!closed) receive(value)
    }, (error) => {
      if (closed) return
      failed(error)
      cancel = clock.after(delay, attempt)
      delay = Math.min(delay * 2, 30_000)
    })
  }
  attempt()
  return () => {
    closed = true
    cancel()
  }
}
