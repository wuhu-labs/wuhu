import { authHeaders } from './auth'
import { ApiError, errorDetail } from './errors'

let unauthorized: (() => void) | null = null

export function onUnauthorized(handler: (() => void) | null): void {
  unauthorized = handler
}

export function notifyUnauthorized(): void {
  unauthorized?.()
}

export async function authorizedRequest(
  url: string,
  init: RequestInit = {},
): Promise<Response> {
  const response = await fetch(url, {
    ...init,
    headers: {
      ...(init.headers as Record<string, string> | undefined),
      ...(await authHeaders()),
    },
  })
  if (!response.ok) {
    const text = await response.text()
    if (response.status === 401) notifyUnauthorized()
    throw new ApiError(response.status, errorDetail(response.status, text))
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
