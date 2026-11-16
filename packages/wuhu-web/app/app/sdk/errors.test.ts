import { ApiError, isTransient, retryAfterMs } from './errors.ts'

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

const refusal = (status: number, code: string) =>
  new ApiError(status, { code, message: code })

Deno.test('a passing status whatever its code, an unavailable space and a broken connection are transient; refusals and server errors are not', () => {
  assertEquals(
    [
      refusal(502, 'internal'),
      refusal(503, 'internal'),
      refusal(504, 'internal'),
      refusal(408, 'internal'),
      refusal(429, 'rateLimited'),
      refusal(502, 'fetchUpstreamUnavailable'),
      refusal(504, 'fetchTimeout'),
      refusal(503, 'fetchIdentityUnavailable'),
      refusal(500, 'unavailable'),
      new TypeError('Failed to fetch'),
      new DOMException('timed out', 'TimeoutError'),
    ].map(isTransient),
    [true, true, true, true, true, true, true, true, true, true, true],
  )
  assertEquals(
    [
      refusal(401, 'unauthorized'),
      refusal(403, 'forbidden'),
      refusal(404, 'notFound'),
      refusal(400, 'invalidArgument'),
      refusal(500, 'internal'),
      refusal(502, 'fetchRedirectInvalid'),
      new Error('the script threw'),
    ].map(isTransient),
    [false, false, false, false, false, false, false],
  )
})

Deno.test('Retry-After is whole seconds, capped at 30 s', () => {
  const after = (value?: string) =>
    retryAfterMs(
      new Headers(value === undefined ? {} : { 'retry-after': value }),
    )
  assertEquals(
    [after('1'), after(' 120 '), after(), after('soon'), after('1.5')],
    [1000, 30_000, undefined, undefined, undefined],
  )
})
