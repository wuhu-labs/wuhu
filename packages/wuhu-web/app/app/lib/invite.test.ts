import { inviteCountdown, inviteUrl } from './invite.ts'

function assertEquals<T>(actual: T, expected: T): void {
  if (actual !== expected) {
    throw new Error(`expected ${String(expected)}, got ${String(actual)}`)
  }
}

const space = `spc_${'a1'.repeat(16)}`

Deno.test('an invite url carries token and space in the fragment', () => {
  assertEquals(
    inviteUrl('https://origin.example.com:5531', 'jt_abc', space),
    `https://origin.example.com:5531/_/enroll#token=jt_abc&space=${space}`,
  )
})

Deno.test('the countdown rounds up to whole minutes', () => {
  const now = new Date('2026-09-03T12:00:00Z')
  const at = (seconds: number) => now.getTime() / 1000 + seconds
  assertEquals(inviteCountdown(at(600), now), 'expires in 10m')
  assertEquals(inviteCountdown(at(541), now), 'expires in 10m')
  assertEquals(inviteCountdown(at(60), now), 'expires in 1m')
  assertEquals(inviteCountdown(at(45), now), 'expires in 45s')
})

Deno.test('a lapsed invite reads as expired', () => {
  const now = new Date('2026-09-03T12:00:00Z')
  assertEquals(inviteCountdown(now.getTime() / 1000, now), 'expired')
  assertEquals(inviteCountdown(now.getTime() / 1000 - 30, now), 'expired')
})
