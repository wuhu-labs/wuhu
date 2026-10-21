import { type Observation, observeProjection } from './observation.ts'
function equal(actual: unknown, expected: unknown) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    )
  }
}

function deferred<T>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((yes) => {
    resolve = yes
  })
  return { promise, resolve }
}

Deno.test('projection follows its read dependency without reopening stat or read', async () => {
  const paints = [deferred<string>(), deferred<string>()]
  let reads = 0
  let stats = 0
  let stopped = 0
  let edit!: (value: string) => void
  const stat: Observation<string> = (receive) => {
    stats++
    queueMicrotask(() => receive('file'))
    return () => {
      stopped++
    }
  }
  const read: Observation<string> = (receive) => {
    reads++
    edit = receive
    queueMicrotask(() => receive('first'))
    return () => {
      stopped++
    }
  }
  const observation = observeProjection(async (get) => {
    await get('stat', stat)
    return await get('read', read)
  })
  let index = 0
  const stop = observation(
    (value) => paints[index++]!.resolve(value),
    (error) => {
      throw error
    },
  )
  equal(await paints[0]!.promise, 'first')
  edit('remote edit')
  equal(await paints[1]!.promise, 'remote edit')
  equal([stats, reads], [1, 1])
  stop()
  equal(stopped, 2)
})
