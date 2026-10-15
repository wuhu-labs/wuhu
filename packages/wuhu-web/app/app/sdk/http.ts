import {
  recoverFromClockRefusal,
  type SignedAssertion,
  signedAssertion,
} from './auth'
import { ApiError, type ErrorDetail, errorDetail } from './errors'

let unauthorized: (() => void) | null = null

export function onUnauthorized(handler: (() => void) | null): void {
  unauthorized = handler
}

export function notifyUnauthorized(): void {
  unauthorized?.()
}

// A 401 carrying one of these reasons refused only the times the browser
// signed; the key is good.
const clockReasons = new Set(['assertionExpired', 'assertionNotYetValid'])

// Whether a refusal means this browser's credential is gone, so the person
// has to sign in again.
export function signsOut(status: number, detail: ErrorDetail): boolean {
  return status === 401 &&
    !(detail.reason != null && clockReasons.has(detail.reason))
}

// Sends with a bearer; a refusal for the bearer's times is re-signed by the
// server's clock and sent once more.
export async function withAssertion(
  send: (headers: Record<string, string>) => Promise<Response>,
): Promise<Response> {
  const signed = await signedAssertion()
  const response = await send(bearer(signed))
  if (response.status !== 401) return response
  const { reason } = errorDetail(401, await response.clone().text())
  if (reason == null || !clockReasons.has(reason)) return response
  await recoverFromClockRefusal(signed?.clock ?? null)
  return send(bearer(await signedAssertion()))
}

function bearer(signed: SignedAssertion | null): Record<string, string> {
  return signed == null ? {} : { authorization: `Bearer ${signed.assertion}` }
}

export async function authorizedRequest(
  url: string,
  init: RequestInit = {},
): Promise<Response> {
  const response = await withAssertion((headers) =>
    fetch(url, {
      ...init,
      headers: {
        ...(init.headers as Record<string, string> | undefined),
        ...headers,
      },
    })
  )
  if (!response.ok) {
    const detail = errorDetail(response.status, await response.text())
    if (signsOut(response.status, detail)) notifyUnauthorized()
    throw new ApiError(response.status, detail)
  }
  return response
}

export async function api<Output>(
  url: string,
  init: RequestInit = {},
): Promise<Output> {
  const response = await authorizedRequest(url, init)
  const text = await response.text()
  return JSON.parse(text) as Output
}

// A person's request acts in the group this names; without it, in the one
// the Host names, which for the SPA is always `shared`.
export function inGroup(group: string): Record<string, string> {
  return { 'wuhu-group': group }
}

export function post<Output>(
  url: string,
  body: unknown,
  headers: Record<string, string> = {},
): Promise<Output> {
  return api(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...headers },
    body: JSON.stringify(body),
  })
}
