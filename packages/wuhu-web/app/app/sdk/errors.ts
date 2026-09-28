export interface ErrorDetail {
  code: string
  message: string
  hint?: string
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
