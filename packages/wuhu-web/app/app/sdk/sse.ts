import { authHeaders } from './auth'
import { notifyUnauthorized } from './http'
import type { EventStream } from './observe'
import { sseParser } from '~/lib/shell-sdk/open-cache.js'

// EventSource cannot carry Authorization, so streams are read over fetch;
// a finished body is reported as an error because observeStore owns
// reconnection and every stream is expected to stay open.
export function openAuthorizedStream(
  url: string,
  headers: Record<string, string> = {},
): EventStream {
  const controller = new AbortController()
  const handlers: {
    open?: () => void
    message?: (data: string) => void
    activity?: () => void
    error?: () => void
  } = {}
  let closed = false

  const fail = () => {
    if (!closed) handlers.error?.()
  }
  ;(async () => {
    const response = await fetch(url, {
      headers: {
        accept: 'text/event-stream',
        ...headers,
        ...(await authHeaders()),
      },
      signal: controller.signal,
    })
    // A proxy or SPA fallback can answer 200 with HTML; treating that as a live
    // stream would sit "live" forever with no events. Require the SSE type.
    const contentType = response.headers.get('content-type') ?? ''
    if (
      !response.ok || response.body == null ||
      !contentType.includes('text/event-stream')
    ) {
      if (response.status === 401) notifyUnauthorized()
      fail()
      return
    }
    handlers.open?.()
    const reader = response.body.getReader()
    const decoder = new TextDecoder()
    const parser = sseParser()
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      if (closed) return
      // Heartbeat comments decode to no message but still prove the
      // connection is alive.
      handlers.activity?.()
      for (
        const { data } of parser.push(decoder.decode(value, { stream: true }))
      ) {
        if (closed) return
        handlers.message?.(data)
      }
    }
    fail()
  })().catch(fail)

  return {
    onOpen(handler) {
      handlers.open = handler
    },
    onMessage(handler) {
      handlers.message = handler
    },
    onActivity(handler) {
      handlers.activity = handler
    },
    onError(handler) {
      handlers.error = handler
    },
    close() {
      closed = true
      controller.abort()
    },
  }
}
