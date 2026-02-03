import type { AppLoadContext, EntryContext } from 'react-router'
import { ServerRouter } from 'react-router'
import { isbot } from 'isbot'
import { renderToReadableStream } from 'react-dom/server.browser'

export const streamTimeout = 5_000

export default async function handleRequest(
  request: Request,
  responseStatusCode: number,
  responseHeaders: Headers,
  routerContext: EntryContext,
  _loadContext: AppLoadContext,
) {
  let shellRendered = false
  const userAgent = request.headers.get('user-agent')
  const isBot = userAgent && isbot(userAgent)
  const waitForAllContent = isBot || routerContext.isSpaMode

  const controller = new AbortController()
  let allReady = false

  const stream = await renderToReadableStream(
    <ServerRouter context={routerContext} url={request.url} />,
    {
      signal: controller.signal,
      onError(error: unknown) {
        if (!shellRendered) {
          return
        }
        console.error('Error streaming rendering:', error)
      },
    },
  )

  stream.allReady.then(() => (allReady = true))
  setTimeout(() => {
    if (!allReady) {
      controller.abort()
    }
  }, streamTimeout + 1000)

  if (waitForAllContent) {
    await stream.allReady
  }

  shellRendered = true
  responseHeaders.set('Content-Type', 'text/html')

  return new Response(stream, {
    headers: responseHeaders,
    status: responseStatusCode,
  })
}
