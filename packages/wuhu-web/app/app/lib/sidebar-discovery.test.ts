import { type RetryClock, retryRead } from './retry-read.ts'
import { assertEquals } from 'jsr:@std/assert@1'
import { discoverSidebarGroups } from './sidebar-discovery.ts'
import type { GroupDetail } from './contract.gen.ts'

Deno.test('parallel group metadata has independent failure, backoff, retained successes and cancellation', async () => {
  const timers: { delay: number; fire: () => void; cancelled: boolean }[] = []
  const clock: RetryClock = {
    after(delay, fire) {
      const timer = { delay, fire, cancelled: false }
      timers.push(timer)
      return () => {
        timer.cancelled = true
      }
    },
  }
  const received: string[] = []
  const failed: string[] = []
  let calls = 0
  const stop = discoverSidebarGroups(
    [{ id: 'shared', readable: true, member: true }, {
      id: 'reader',
      readable: true,
      member: false,
    }, { id: 'unreadable', readable: false }],
    (id) => {
      if (id === 'reader' && calls++ < 2) {
        return Promise.reject(new Error('offline'))
      }
      return Promise.resolve(
        {
          id,
          alias: id,
          personal: false,
          open: true,
          secrets: 'owner',
          entries: [],
        } satisfies GroupDetail,
      )
    },
    (id) => received.push(id),
    (id) => failed.push(id),
    clock,
  )
  await Promise.resolve()
  await Promise.resolve()
  assertEquals(received, ['shared'])
  assertEquals(failed, ['reader'])
  assertEquals(timers[0].delay, 1000)
  timers[0].fire()
  await Promise.resolve()
  await Promise.resolve()
  assertEquals(timers[1].delay, 2000)
  timers[1].fire()
  await Promise.resolve()
  await Promise.resolve()
  assertEquals(received, ['shared', 'reader'])
  stop()
  assertEquals(timers[1].cancelled, true)
})

Deno.test('persona adoption retry is bounded backoff and can be cancelled', async () => {
  let callback = () => {}
  let cancelled = false
  const values: string[] = []
  const delays: number[] = []
  let calls = 0
  const stop = retryRead(
    () =>
      calls++ === 0
        ? Promise.reject(new Error('transient'))
        : Promise.resolve('principal'),
    (value) => values.push(value),
    () => {},
    {
      after(delay, fire) {
        delays.push(delay)
        callback = fire
        return () => {
          cancelled = true
        }
      },
    },
  )
  await Promise.resolve()
  await Promise.resolve()
  assertEquals(delays, [1000])
  callback()
  await Promise.resolve()
  await Promise.resolve()
  assertEquals(values, ['principal'])
  stop()
  assertEquals(cancelled, true)
})
