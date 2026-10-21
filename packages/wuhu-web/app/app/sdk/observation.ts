export type Observation<Value> = (
  receive: (value: Value) => void,
  failure: (failure: unknown) => void,
) => () => void

export function observeProjection<Value>(
  project: (
    get: <T>(key: string, observation: Observation<T>) => Promise<T>,
  ) => Promise<Value>,
): Observation<Value> {
  return (receive, failure) => {
    const waiting = Symbol()
    let closed = false
    let version = 0
    const dependencies = new Map<
      string,
      { value?: Promise<unknown>; stop(): void }
    >()
    const run = async () => {
      const current = ++version
      try {
        const value = await project(
          <T>(key: string, observation: Observation<T>) => {
            if (closed) throw waiting
            let dependency = dependencies.get(key)
            if (dependency === undefined) {
              dependency = { stop: () => {} }
              dependencies.set(key, dependency)
              const update = (value: Promise<T>) => {
                dependency!.value = value
                void value.catch(() => {})
                void run()
              }
              dependency.stop = observation(
                (value) => update(Promise.resolve(value)),
                (error) => update(Promise.reject(error)),
              )
            }
            if (dependency.value === undefined) throw waiting
            return dependency.value as Promise<T>
          },
        )
        if (!closed && current === version) receive(value)
      } catch (error) {
        if (!closed && current === version && error !== waiting) failure(error)
      }
    }
    void run()
    return () => {
      closed = true
      version++
      for (const dependency of dependencies.values()) dependency.stop()
    }
  }
}
