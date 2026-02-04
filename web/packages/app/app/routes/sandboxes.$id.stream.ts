import type { Route } from './+types/sandboxes.$id.stream.ts'

export async function loader({ params, request }: Route.LoaderArgs) {
  const apiUrl = Deno.env.get('API_URL')
  if (!apiUrl) {
    return new Response('API_URL environment variable is not configured', {
      status: 500,
    })
  }
  const id = params.id
  if (!id) {
    return new Response('Sandbox id is required', { status: 400 })
  }

  const sandboxResponse = await fetch(`${apiUrl}/sandboxes/${id}`)
  if (!sandboxResponse.ok) {
    return new Response('Sandbox not found', { status: 404 })
  }
  const data = await sandboxResponse.json()
  const sandbox = data?.sandbox
  const podIp = sandbox?.podIp as string | null | undefined
  const daemonPort = sandbox?.daemonPort as number | undefined
  if (!podIp || !daemonPort) {
    return new Response('Sandbox pod not ready', { status: 503 })
  }

  const url = new URL(request.url)
  const cursor = url.searchParams.get('cursor') ?? '0'
  const follow = url.searchParams.get('follow') ?? '1'

  let upstream: Response
  try {
    upstream = await fetch(
      `http://${podIp}:${daemonPort}/stream?cursor=${
        encodeURIComponent(cursor)
      }&follow=${encodeURIComponent(follow)}`,
      {
        headers: {
          accept: 'text/event-stream',
        },
      },
    )
  } catch {
    return new Response('Sandbox daemon not ready', { status: 503 })
  }

  if (!upstream.ok || !upstream.body) {
    const errorText = await upstream.text()
    return new Response(errorText || 'Upstream stream failed', {
      status: upstream.status || 502,
    })
  }

  return new Response(upstream.body, {
    status: upstream.status,
    headers: {
      'content-type': 'text/event-stream; charset=utf-8',
      'cache-control': 'no-cache',
      connection: 'keep-alive',
    },
  })
}
