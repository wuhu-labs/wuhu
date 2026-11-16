export interface ErrorDetail {
  code: string
  message: string
  hint?: string
  reason?: string
}

export class ApiError extends Error {
  constructor(readonly status: number, readonly detail: ErrorDetail) {
    super(detail.message)
    this.name = 'ApiError'
  }

  get code(): string {
    return this.detail.code
  }

  get hint(): string | undefined {
    return this.detail.hint
  }
}

export function errorDetail(status: number, text: string): ErrorDetail {
  try {
    const parsed = JSON.parse(text) as Record<string, unknown>
    if (typeof parsed.message === 'string') {
      return {
        code: typeof parsed.code === 'string' ? parsed.code : 'internal',
        message: parsed.message,
        ...(typeof parsed.hint === 'string' ? { hint: parsed.hint } : {}),
        ...(typeof parsed.reason === 'string' ? { reason: parsed.reason } : {}),
      }
    }
  } catch {
    // fall through to the status line
  }
  return { code: 'internal', message: `HTTP ${status}: ${text}` }
}

export function errorMessage(failure: unknown): string {
  return failure instanceof Error ? failure.message : String(failure)
}

export function isFileRefusal(failure: unknown): boolean {
  return failure instanceof ApiError && [
    'notFound',
    'invalidArgument',
    'forbidden',
    'unsupported',
    'invalidPath',
    'byteLimitExceeded',
    'unknownKind',
    'conflict',
  ].includes(failure.code)
}

// A status that passes on its own (a timeout, throttling, a gateway or a
// server between owners), the `unavailable` code, or a connection that broke:
// something to wait out and retry. Only a refusal code overrides the status.
const transientStatuses = [408, 429, 502, 503, 504]
const refusalCodes = ['fetchRedirectInvalid']

export function isTransient(failure: unknown): boolean {
  if (failure instanceof ApiError) {
    return !refusalCodes.includes(failure.code) &&
      (failure.code === 'unavailable' ||
        transientStatuses.includes(failure.status))
  }
  return failure instanceof TypeError ||
    (failure instanceof DOMException && failure.name === 'TimeoutError')
}

const maxRetryAfterMs = 30_000

export function retryAfterMs(headers: Headers): number | undefined {
  const value = headers.get('retry-after')?.trim()
  if (value === undefined || !/^\d+$/.test(value)) return undefined
  return Math.min(Number(value) * 1000, maxRetryAfterMs)
}
