import { Hono } from '@hono/hono'
import type { Context } from '@hono/hono'
import { cors } from '@hono/hono/cors'
import { streamSSE } from '@hono/hono/streaming'
import { loadConfig } from './src/config.ts'
import { db } from './src/db.ts'
import { createKubeClient } from './src/k8s.ts'
import type { SandboxRecord } from './src/sandbox-service.ts'
import { RepoService } from './src/repos.ts'
import {
  createSandbox,
  getSandbox,
  listSandboxes,
  refreshSandboxes,
  refreshSandboxPod,
  terminateSandbox,
} from './src/sandbox-service.ts'
import { fetchSandboxMessages, persistSandboxState } from './src/state.ts'

const app = new Hono()
const config = loadConfig()
const kubeClientPromise = createKubeClient(config.kube)
const repoService = new RepoService({
  token: config.github.token,
  allowedOrgs: config.github.allowedOrgs,
  redisUrl: config.redis.url,
})

app.use('*', cors())

function readEnvTrimmed(name: string): string | undefined {
  const raw = Deno.env.get(name)
  if (!raw) return undefined
  const trimmed = raw.trim()
  return trimmed.length ? trimmed : undefined
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null
}

function parseNumberField(
  body: Record<string, unknown>,
  key: string,
): number | null {
  const value = body[key]
  if (typeof value === 'number') return value
  if (typeof value === 'string' && value.trim().length) {
    const parsed = Number(value)
    return Number.isFinite(parsed) ? parsed : null
  }
  return null
}

function parsePreviewHost(host: string): { id: string; port: number } | null {
  const hostname = host.split(':')[0]
  const suffix = `.${config.sandbox.previewDomain}`
  if (!hostname.endsWith(suffix)) return null
  const prefix = hostname.slice(0, -suffix.length)
  const dashIndex = prefix.lastIndexOf('-')
  if (dashIndex <= 0) return null
  const id = prefix.slice(0, dashIndex)
  const port = Number(prefix.slice(dashIndex + 1))
  if (!Number.isInteger(port)) return null
  return { id, port }
}

async function proxyPreviewRequest(c: Context): Promise<Response | null> {
  const host = c.req.header('host') ?? c.req.header('Host')
  if (!host) return null
  const parsed = parsePreviewHost(host)
  if (!parsed) return null

  const kubeClient = await kubeClientPromise
  const record = await getSandbox(parsed.id)
  if (!record) {
    return c.json({ error: 'sandbox_not_found' }, 404)
  }
  const refreshed = await refreshSandboxPod(kubeClient, record)
  if (!refreshed.podIp) {
    return c.json({ error: 'pod_not_ready' }, 503)
  }
  if (parsed.port !== refreshed.previewPort) {
    return c.json({ error: 'preview_port_mismatch' }, 404)
  }

  const targetUrl = new URL(c.req.url)
  targetUrl.protocol = 'http:'
  targetUrl.hostname = refreshed.podIp
  targetUrl.port = String(parsed.port)

  const headers = new Headers(c.req.raw.headers)
  headers.delete('host')

  const response = await fetch(targetUrl.toString(), {
    method: c.req.method,
    headers,
    body: c.req.raw.body,
    redirect: 'manual',
  })

  return new Response(response.body, {
    status: response.status,
    headers: response.headers,
  })
}

app.use('*', async (c, next) => {
  const proxied = await proxyPreviewRequest(c)
  if (proxied) return proxied
  await next()
})

function buildPreviewUrl(id: string, port: number): string {
  return `https://${id}-${port}.${config.sandbox.previewDomain}`
}

function serializeSandbox(record: SandboxRecord) {
  return {
    ...record,
    previewUrl: buildPreviewUrl(record.id, record.previewPort),
  }
}

async function tryShutdownDaemon(record: {
  podIp: string | null
  daemonPort: number
}) {
  if (!record.podIp) return
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), 1500)
  try {
    await fetch(`http://${record.podIp}:${record.daemonPort}/shutdown`, {
      method: 'POST',
      signal: controller.signal,
    })
  } catch {
    // best-effort
  } finally {
    clearTimeout(timeout)
  }
}

async function waitForSandboxReady(
  client: Awaited<ReturnType<typeof createKubeClient>>,
  record: SandboxRecord,
  options?: { attempts?: number; delayMs?: number },
): Promise<SandboxRecord> {
  const attempts = options?.attempts ?? 30
  const delayMs = options?.delayMs ?? 1000
  let current = record
  for (let i = 0; i < attempts; i++) {
    current = await refreshSandboxPod(client, current)
    if (current.podIp) return current
    await new Promise((resolve) => setTimeout(resolve, delayMs))
  }
  return current
}

async function waitForDaemonHealthy(
  record: { podIp: string | null; daemonPort: number },
  options?: { attempts?: number; delayMs?: number; timeoutMs?: number },
): Promise<boolean> {
  if (!record.podIp) return false
  const attempts = options?.attempts ?? 45
  const delayMs = options?.delayMs ?? 1000
  const timeoutMs = options?.timeoutMs ?? 1500
  for (let i = 0; i < attempts; i++) {
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), timeoutMs)
    try {
      const res = await fetch(
        `http://${record.podIp}:${record.daemonPort}/health`,
        { signal: controller.signal },
      )
      if (res.ok) return true
    } catch {
      // ignore
    } finally {
      clearTimeout(timer)
    }
    await new Promise((resolve) => setTimeout(resolve, delayMs))
  }
  return false
}

async function postDaemonCredentials(
  record: { podIp: string | null; daemonPort: number },
  token: string | undefined,
): Promise<void> {
  if (!record.podIp) return
  try {
    const response = await fetch(
      `http://${record.podIp}:${record.daemonPort}/credentials`,
      {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          version: 'core',
          llm: {
            openaiApiKey: readEnvTrimmed('OPENAI_API_KEY') ?? null,
            anthropicApiKey: readEnvTrimmed('ANTHROPIC_API_KEY') ?? null,
          },
          ...(token ? { github: { token } } : {}),
        }),
      },
    )
    if (!response.ok) {
      console.warn('sandbox credentials failed', await response.text())
    }
  } catch (error) {
    console.warn('sandbox credentials request failed', error)
  }
}

async function initSandboxRepo(
  record: { podIp: string | null; daemonPort: number },
  repoFullName: string,
  prompt: string,
): Promise<void> {
  if (!record.podIp) return
  try {
    const response = await fetch(
      `http://${record.podIp}:${record.daemonPort}/init`,
      {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          workspace: {
            repos: [
              {
                id: repoFullName,
                source: `github:${repoFullName}`,
                path: 'repo',
              },
            ],
          },
          prompt: {
            message: prompt,
            streamingBehavior: 'followUp',
          },
        }),
      },
    )
    if (!response.ok) {
      console.warn('sandbox init failed', await response.text())
    }
  } catch (error) {
    console.warn('sandbox init request failed', error)
  }
}

type DaemonStreamEnvelope = {
  cursor?: number
  event?: unknown
}

function parseSseChunk(chunk: string): { data?: string; event?: string } {
  const lines = chunk.split(/\r?\n/)
  const dataLines: string[] = []
  let event: string | undefined
  for (const line of lines) {
    if (!line || line.startsWith(':')) continue
    if (line.startsWith('event:')) {
      event = line.slice('event:'.length).trimStart()
      continue
    }
    if (line.startsWith('data:')) {
      dataLines.push(line.slice('data:'.length).trimStart())
    }
  }
  const data = dataLines.length ? dataLines.join('\n') : undefined
  return { data, event }
}

async function proxyDaemonSse(
  c: Context,
  record: SandboxRecord,
  options: {
    cursor: number
    filter: (event: Record<string, unknown>) => boolean
    map: (event: Record<string, unknown>) => Record<string, unknown>
  },
): Promise<Response> {
  if (!record.podIp) {
    return c.json({ error: 'pod_not_ready' }, 503)
  }
  const upstreamUrl =
    `http://${record.podIp}:${record.daemonPort}/stream?cursor=${options.cursor}&follow=1`

  const upstreamController = new AbortController()
  const upstreamRes = await fetch(upstreamUrl, {
    headers: { accept: 'text/event-stream' },
    signal: upstreamController.signal,
  })
  if (!upstreamRes.ok || !upstreamRes.body) {
    const text = await upstreamRes.text().catch(() => '')
    return c.json(
      { error: 'upstream_stream_failed', status: upstreamRes.status, text },
      502,
    )
  }
  const upstreamBody = upstreamRes.body

  return streamSSE(c, async (stream) => {
    stream.onAbort(() => upstreamController.abort())
    const reader = upstreamBody.getReader()
    const decoder = new TextDecoder()
    let buffer = ''

    try {
      while (!stream.aborted) {
        const { value, done } = await reader.read()
        if (done) break
        buffer += decoder.decode(value, { stream: true })
        const parts = buffer.split(/\r?\n\r?\n/)
        buffer = parts.pop() ?? ''
        for (const part of parts) {
          if (!part.trim()) continue
          const parsed = parseSseChunk(part)
          if (!parsed.data) continue
          if (parsed.event === 'heartbeat') continue
          let env: DaemonStreamEnvelope
          try {
            env = JSON.parse(parsed.data) as DaemonStreamEnvelope
          } catch {
            continue
          }
          const cursor = typeof env.cursor === 'number' ? env.cursor : null
          if (!cursor) continue
          const rawEvent = env.event
          if (!isRecord(rawEvent)) continue
          if (!options.filter(rawEvent)) continue
          const mapped = options.map(rawEvent)
          await stream.writeSSE({
            id: String(cursor),
            data: JSON.stringify({ cursor, event: mapped }),
          })
        }
      }
    } catch {
      // Ignore stream errors; disconnect will end the request.
    } finally {
      try {
        await reader.cancel()
      } catch {
        // ignore
      }
    }
  })
}

app.get('/', (c) => {
  return c.json({
    name: 'wuhu-core',
    version: '0.1.0',
    sandboxImage: config.sandbox.image,
  })
})

app.get('/health', (c) => {
  return c.json({ status: 'ok' })
})

app.get('/repos', async (c) => {
  try {
    const repos = await repoService.listRepos()
    return c.json({ repos })
  } catch (error) {
    console.error('Failed to list repos', error)
    const message = error instanceof Error ? error.message : 'repo_list_failed'
    return c.json({ error: message }, 500)
  }
})

app.get('/sandboxes', async (c) => {
  const includeTerminated = c.req.query('all') === 'true'
  const refresh = c.req.query('refresh') !== 'false'
  try {
    const kubeClient = await kubeClientPromise
    let records = await listSandboxes({ includeTerminated })
    if (refresh) {
      records = await refreshSandboxes(kubeClient, records)
    }
    return c.json({
      sandboxes: records.map((record) => serializeSandbox(record)),
    })
  } catch (error) {
    console.error('Failed to list sandboxes', error)
    return c.json({ error: 'sandbox_list_failed' }, 500)
  }
})

app.post('/sandboxes', async (c) => {
  let body: { name?: string; repo?: string; prompt?: string } = {}
  try {
    body = await c.req.json()
  } catch {
    body = {}
  }
  try {
    const repo = String(body.repo ?? '').trim()
    if (!repo) {
      return c.json({ error: 'missing_repo' }, 400)
    }
    const prompt = String(body.prompt ?? '').trim() ||
      'Tell me what this repo is about'
    const repoParts = repo.split('/')
    if (repoParts.length !== 2 || !repoParts[0] || !repoParts[1]) {
      return c.json({ error: 'invalid_repo' }, 400)
    }
    if (
      config.github.allowedOrgs.length > 0 &&
      !config.github.allowedOrgs.includes(repoParts[0])
    ) {
      return c.json({ error: 'repo_not_allowed' }, 400)
    }
    const kubeClient = await kubeClientPromise
    const { record } = await createSandbox(kubeClient, config.sandbox, {
      name: body.name ?? null,
      repoFullName: repo,
    })

    const ready = await waitForSandboxReady(kubeClient, record, {
      attempts: 60,
      delayMs: 1000,
    })
    if (!ready.podIp) {
      return c.json({ error: 'pod_not_ready' }, 503)
    }
    const healthy = await waitForDaemonHealthy(ready, {
      attempts: 60,
      delayMs: 1000,
      timeoutMs: 1500,
    })
    if (!healthy) {
      return c.json({ error: 'daemon_not_ready' }, 503)
    }

    await postDaemonCredentials(ready, config.github.token)
    void initSandboxRepo(ready, repo, prompt)

    return c.json({ sandbox: serializeSandbox(ready) }, 201)
  } catch (error) {
    console.error('Failed to create sandbox', error)
    return c.json({ error: 'sandbox_create_failed' }, 500)
  }
})

app.get('/sandboxes/:id', async (c) => {
  const id = c.req.param('id')
  try {
    const kubeClient = await kubeClientPromise
    const record = await getSandbox(id)
    if (!record) {
      return c.json({ error: 'not_found' }, 404)
    }
    const refreshed = await refreshSandboxPod(kubeClient, record)
    return c.json({ sandbox: serializeSandbox(refreshed) })
  } catch (error) {
    console.error('Failed to fetch sandbox', error)
    return c.json({ error: 'sandbox_fetch_failed' }, 500)
  }
})

app.post('/sandboxes/:id/kill', async (c) => {
  const id = c.req.param('id')
  try {
    const kubeClient = await kubeClientPromise
    const record = await getSandbox(id)
    if (!record) {
      return c.json({ error: 'not_found' }, 404)
    }
    const refreshed = await refreshSandboxPod(kubeClient, record)
    await tryShutdownDaemon(refreshed)
    const terminated = await terminateSandbox(kubeClient, refreshed)
    return c.json({ sandbox: serializeSandbox(terminated) })
  } catch (error) {
    console.error('Failed to terminate sandbox', error)
    return c.json({ error: 'sandbox_kill_failed' }, 500)
  }
})

app.post('/sandboxes/:id/prompt', async (c) => {
  const id = c.req.param('id')
  let body: { message?: string; streamingBehavior?: 'steer' | 'followUp' } = {}
  try {
    body = await c.req.json()
  } catch {
    body = {}
  }
  const message = String(body.message ?? '').trim()
  if (!message) return c.json({ error: 'missing_message' }, 400)

  try {
    const kubeClient = await kubeClientPromise
    const record = await getSandbox(id)
    if (!record) return c.json({ error: 'not_found' }, 404)
    const refreshed = await refreshSandboxPod(kubeClient, record)
    if (!refreshed.podIp) return c.json({ error: 'pod_not_ready' }, 503)

    const res = await fetch(
      `http://${refreshed.podIp}:${refreshed.daemonPort}/prompt`,
      {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          message,
          streamingBehavior: body.streamingBehavior ?? 'followUp',
        }),
      },
    )
    const text = await res.text()
    return new Response(text, {
      status: res.status,
      headers: { 'content-type': 'application/json' },
    })
  } catch (error) {
    console.error('Failed to proxy prompt', error)
    return c.json({ error: 'sandbox_prompt_failed' }, 500)
  }
})

app.post('/sandboxes/:id/abort', async (c) => {
  const id = c.req.param('id')
  let body: { reason?: string } = {}
  try {
    body = await c.req.json()
  } catch {
    body = {}
  }
  try {
    const kubeClient = await kubeClientPromise
    const record = await getSandbox(id)
    if (!record) return c.json({ error: 'not_found' }, 404)
    const refreshed = await refreshSandboxPod(kubeClient, record)
    if (!refreshed.podIp) return c.json({ error: 'pod_not_ready' }, 503)

    const res = await fetch(
      `http://${refreshed.podIp}:${refreshed.daemonPort}/abort`,
      {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(body),
      },
    )
    const text = await res.text()
    return new Response(text, {
      status: res.status,
      headers: { 'content-type': 'application/json' },
    })
  } catch (error) {
    console.error('Failed to proxy abort', error)
    return c.json({ error: 'sandbox_abort_failed' }, 500)
  }
})

app.post('/sandboxes/:id/state', async (c) => {
  const id = c.req.param('id')
  let body: unknown = {}
  try {
    body = await c.req.json()
  } catch {
    body = {}
  }
  if (!isRecord(body)) return c.json({ error: 'invalid_body' }, 400)

  const cursorField = parseNumberField(body, 'cursor')
  if (
    typeof cursorField !== 'number' || !Number.isInteger(cursorField) ||
    cursorField < 0
  ) {
    return c.json({ error: 'invalid_cursor' }, 400)
  }
  const cursor = cursorField

  const rawMessages = body.messages
  if (!Array.isArray(rawMessages)) {
    return c.json({ error: 'invalid_messages' }, 400)
  }

  const messages: Array<{
    cursor: number
    role: string
    content: string
    toolName: string | null
    toolCallId: string | null
    turnIndex: number
  }> = []
  for (const entry of rawMessages) {
    if (!isRecord(entry)) return c.json({ error: 'invalid_message' }, 400)
    const entryCursorField = parseNumberField(entry, 'cursor')
    const role = entry.role
    const content = entry.content
    const turnIndexField = parseNumberField(entry, 'turnIndex')
    if (
      typeof entryCursorField !== 'number' ||
      !Number.isInteger(entryCursorField) ||
      entryCursorField < 0 ||
      typeof role !== 'string' || !role.trim().length ||
      typeof content !== 'string' ||
      typeof turnIndexField !== 'number' ||
      !Number.isInteger(turnIndexField) ||
      turnIndexField < 0
    ) {
      return c.json({ error: 'invalid_message' }, 400)
    }
    const toolName = typeof entry.toolName === 'string' ? entry.toolName : null
    const toolCallId = typeof entry.toolCallId === 'string'
      ? entry.toolCallId
      : null
    messages.push({
      cursor: entryCursorField,
      role,
      content,
      toolName,
      toolCallId,
      turnIndex: turnIndexField,
    })
  }

  const maxMessageCursor = messages.reduce(
    (acc, message) => Math.max(acc, message.cursor),
    0,
  )
  if (cursor < maxMessageCursor) {
    return c.json({ error: 'cursor_less_than_messages' }, 400)
  }

  try {
    const record = await getSandbox(id)
    if (!record) return c.json({ error: 'not_found' }, 404)

    const persisted = await persistSandboxState(db, id, { cursor, messages })
    return c.json({ ok: true, cursor: persisted.cursor })
  } catch (error) {
    console.error('Failed to persist sandbox state', error)
    return c.json({ error: 'sandbox_state_persist_failed' }, 500)
  }
})

app.get('/sandboxes/:id/messages', async (c) => {
  const id = c.req.param('id')
  const parsedCursor = Number(c.req.query('cursor') ?? '0')
  const cursor = Number.isFinite(parsedCursor)
    ? Math.max(0, Math.floor(parsedCursor))
    : 0
  const limitRaw = c.req.query('limit')
  const parsedLimit = limitRaw ? Number(limitRaw) : 100
  const limit = Number.isFinite(parsedLimit) ? Math.floor(parsedLimit) : 100
  const boundedLimit = Math.min(Math.max(limit, 0), 500)

  try {
    const record = await getSandbox(id)
    if (!record) return c.json({ error: 'not_found' }, 404)

    const result = await fetchSandboxMessages(db, id, {
      cursorExclusive: cursor,
      limit: boundedLimit,
    })
    return c.json(result)
  } catch (error) {
    console.error('Failed to fetch sandbox messages', error)
    return c.json({ error: 'sandbox_messages_fetch_failed' }, 500)
  }
})

app.get('/sandboxes/:id/stream/control', async (c) => {
  const id = c.req.param('id')
  const cursor = Number(c.req.query('cursor') ?? '0') || 0

  try {
    const kubeClient = await kubeClientPromise
    const record = await getSandbox(id)
    if (!record) return c.json({ error: 'not_found' }, 404)
    const refreshed = await refreshSandboxPod(kubeClient, record)
    const allowedTypes = new Set([
      'sandbox_ready',
      'repo_cloned',
      'repo_clone_error',
      'init_complete',
      'prompt_queued',
      'daemon_error',
      'sandbox_terminated',
    ])
    return await proxyDaemonSse(c, refreshed, {
      cursor,
      filter: (event) =>
        event.source === 'daemon' &&
        typeof event.type === 'string' &&
        allowedTypes.has(event.type),
      map: (event) => {
        const { source: _source, ...rest } = event
        return rest
      },
    })
  } catch (error) {
    console.error('Failed to stream control events', error)
    return c.json({ error: 'sandbox_stream_failed' }, 500)
  }
})

app.get('/sandboxes/:id/stream/coding', async (c) => {
  const id = c.req.param('id')
  const cursor = Number(c.req.query('cursor') ?? '0') || 0

  try {
    const kubeClient = await kubeClientPromise
    const record = await getSandbox(id)
    if (!record) return c.json({ error: 'not_found' }, 404)
    const refreshed = await refreshSandboxPod(kubeClient, record)
    const allowedTypes = new Set([
      'turn_start',
      'turn_end',
      'message_start',
      'message_update',
      'message_end',
      'tool_execution_start',
      'tool_execution_update',
      'tool_execution_end',
    ])
    return await proxyDaemonSse(c, refreshed, {
      cursor,
      filter: (event) => {
        if (event.source !== 'agent') return false
        const type = typeof event.type === 'string' ? event.type : ''
        return allowedTypes.has(type)
      },
      map: (event) => {
        const payload = isRecord(event.payload) ? event.payload : {}
        const type = typeof payload.type === 'string'
          ? payload.type
          : (typeof event.type === 'string' ? event.type : 'unknown')
        return {
          ...payload,
          type,
          timestamp: typeof event.timestamp === 'number'
            ? event.timestamp
            : Date.now(),
        }
      },
    })
  } catch (error) {
    console.error('Failed to stream coding events', error)
    return c.json({ error: 'sandbox_stream_failed' }, 500)
  }
})

app.get('/sandbox-lookup', async (c) => {
  const id = c.req.query('id')
  if (!id) {
    return c.json({ error: 'missing_id' }, 400)
  }
  try {
    const kubeClient = await kubeClientPromise
    const record = await getSandbox(id)
    if (!record) {
      return c.json({ error: 'not_found' }, 404)
    }
    const refreshed = await refreshSandboxPod(kubeClient, record)
    if (!refreshed.podIp) {
      return c.json({ error: 'pod_not_ready' }, 503)
    }
    return c.json({
      ok: true,
      podIp: refreshed.podIp,
    })
  } catch (error) {
    console.error('Failed to resolve sandbox lookup', error)
    return c.json({ error: 'sandbox_lookup_failed' }, 500)
  }
})

console.log(
  `Server running on http://localhost:${config.port} (sandboxImage=${config.sandbox.image})`,
)

Deno.serve({ port: config.port }, app.fetch)
