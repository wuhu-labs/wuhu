import { coalescedRefresh } from './coalesced-refresh.ts'

function result<T>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((yes) => {
    resolve = yes
  })
  return { promise, resolve }
}

Deno.test('refresh coalesces overlapping requests and suppresses results after close', async () => {
  const first = result<number>()
  const started = result<void>()
  const second = result<number>()
  let requests = 0
  const refresh = coalescedRefresh(() => {
    started.resolve()
    return ++requests === 1 ? first.promise : Promise.resolve(2)
  }, (value) => {
    if (value === 2) second.resolve(value)
  }, (error) => {
    throw error
  })
  void refresh.run()
  await started.promise
  void refresh.run()
  void refresh.run()
  first.resolve(1)
  await second.promise
  if (requests !== 2) throw new Error(`expected two requests, got ${requests}`)
  refresh.close()
  await refresh.run()
  if (requests !== 2) throw new Error('closed refresh requested again')
})

Deno.test('closing a refresh suppresses an already-running result', async () => {
  const response = result<number>()
  const started = result<void>()
  let delivered = false
  const refresh = coalescedRefresh(() => {
    started.resolve()
    return response.promise
  }, () => {
    delivered = true
  }, (error) => {
    throw error
  })
  const request = refresh.run()
  await started.promise
  refresh.close()
  response.resolve(1)
  await request
  if (delivered) throw new Error('closed refresh delivered its result')
})
