const encoder = new TextEncoder()
const decoder = new TextDecoder()

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

async function readLines(
  stream: ReadableStream<Uint8Array> | null,
  onLine: (line: string) => void,
): Promise<void> {
  if (!stream) return
  const reader = stream.getReader()
  let buf = ''
  while (true) {
    const { value, done } = await reader.read()
    if (done) break
    buf += decoder.decode(value, { stream: true })
    const lines = buf.split(/\r?\n/)
    buf = lines.pop() ?? ''
    for (const line of lines) onLine(line)
  }
  if (buf) onLine(buf)
}

function envRequired(name: string): string {
  const value = Deno.env.get(name)?.trim()
  if (!value) {
    throw new Error(`Missing required env var: ${name}`)
  }
  return value
}

function findFreePort(start: number): number {
  for (let port = start; port < start + 50; port++) {
    try {
      const listener = Deno.listen({ hostname: '127.0.0.1', port })
      listener.close()
      return port
    } catch {
      // try next port
    }
  }
  throw new Error(`unable to find a free localhost port near ${start}`)
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

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null
}

function extractAssistantText(payload: unknown): string | null {
  if (!isRecord(payload)) return null
  const message = payload.message
  if (!isRecord(message)) return null
  if (!message) return null
  const role = typeof message.role === 'string' ? message.role : ''
  if (role !== 'assistant') return null
  const content = message.content
  if (typeof content === 'string') return content.trim()
  if (Array.isArray(content)) {
    let text = ''
    for (const item of content) {
      if (
        isRecord(item) &&
        item.type === 'text' &&
        typeof item.text === 'string'
      ) {
        text += item.text
      }
    }
    return text.trim()
  }
  return null
}

function looksLikeDirectoryListing(text: string): boolean {
  const lower = text.toLowerCase()
  const needles = [
    'core',
    'web',
    'packages',
    'notes',
    'readme',
    'dockerfile',
    '.ts',
    '.md',
  ]
  return needles.some((needle) => lower.includes(needle))
}

async function waitForHealth(
  baseUrl: string,
  timeoutMs: number,
): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${baseUrl}/health`)
      if (res.ok) return
    } catch {
      // ignore
    }
    await sleep(1000)
  }
  throw new Error(`daemon did not become healthy within ${timeoutMs}ms`)
}

async function main() {
  const githubToken = envRequired('GITHUB_TOKEN')
  const agentMode = (Deno.env.get('SMOKE_AGENT_MODE')?.trim() || 'pi-rpc')
    .toLowerCase()
  const openaiKey = agentMode === 'pi-rpc'
    ? envRequired('OPENAI_API_KEY')
    : (Deno.env.get('OPENAI_API_KEY')?.trim() || '')

  const image = Deno.env.get('SMOKE_IMAGE')?.trim() || 'wuhu-sandbox:latest'
  const startPort = Number(Deno.env.get('SMOKE_PORT') ?? 18787)
  const port = findFreePort(startPort)
  const baseUrl = `http://127.0.0.1:${port}`
  const timeoutMs = Number(Deno.env.get('SMOKE_TIMEOUT_MS') ?? 420_000)
  const readyTimeoutMs = Number(
    Deno.env.get('SMOKE_READY_TIMEOUT_MS') ?? 60_000,
  )

  const repo = Deno.env.get('SMOKE_REPO')?.trim() ||
    Deno.env.get('GITHUB_REPOSITORY')?.trim() ||
    'wuhu-labs/wuhu'
  const repoBranch = Deno.env.get('SMOKE_BRANCH')?.trim() ||
    Deno.env.get('GITHUB_REF_NAME')?.trim() ||
    undefined

  const prompt = Deno.env.get('SMOKE_PROMPT')?.trim() ||
    "show me what's in pwd"

  const containerName = `wuhu-sandbox-smoke-${Date.now()}`

  console.log(`Starting sandbox container ${image} on ${baseUrl}...`)
  const child = new Deno.Command('docker', {
    args: [
      'run',
      '--rm',
      '--name',
      containerName,
      '-p',
      `127.0.0.1:${port}:8787`,
      '-e',
      `SANDBOX_DAEMON_AGENT_MODE=${agentMode}`,
      image,
    ],
    stdin: 'null',
    stdout: 'piped',
    stderr: 'piped',
  }).spawn()

  void readLines(child.stdout, (line) => {
    if (!line) return
    console.log(`[sandbox] ${line}`)
  })
  void readLines(child.stderr, (line) => {
    if (!line) return
    console.error(`[sandbox] ${line}`)
  })

  try {
    const ready = await Promise.race([
      waitForHealth(baseUrl, readyTimeoutMs).then(
        () => ({ kind: 'health' } as const),
      ),
      child.status.then((status) => ({ kind: 'exit', status }) as const),
    ])
    if (ready.kind === 'exit') {
      throw new Error(
        `sandbox container exited early (code=${ready.status.code} signal=${ready.status.signal})`,
      )
    }

    console.log('Injecting credentials...')
    const credRes = await fetch(`${baseUrl}/credentials`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        version: 'smoke',
        llm: openaiKey ? { openaiApiKey: openaiKey } : undefined,
        github: {
          token: githubToken,
          username: Deno.env.get('GITHUB_ACTOR') ?? undefined,
        },
      }),
    })
    if (!credRes.ok) {
      const text = await credRes.text()
      throw new Error(`POST /credentials failed: ${credRes.status} ${text}`)
    }

    console.log(
      `Initializing workspace (repo=${repo}${
        repoBranch ? `#${repoBranch}` : ''
      })...`,
    )
    const initBody: Record<string, unknown> = {
      workspace: {
        repos: [
          {
            id: 'repo',
            source: `github:${repo}`,
            path: 'repo',
            ...(repoBranch ? { branch: repoBranch } : {}),
          },
        ],
      },
    }
    const initRes = await fetch(`${baseUrl}/init`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(initBody),
    })
    if (!initRes.ok) {
      const text = await initRes.text()
      throw new Error(`POST /init failed: ${initRes.status} ${text}`)
    }
    const initJson = await initRes.json()
    if (!initJson?.ok) {
      throw new Error(
        `POST /init returned ok=false: ${JSON.stringify(initJson)}`,
      )
    }

    console.log('Opening event stream...')
    const streamRes = await fetch(`${baseUrl}/stream?cursor=0&follow=1`, {
      headers: { accept: 'text/event-stream' },
    })
    if (!streamRes.ok || !streamRes.body) {
      const text = await streamRes.text()
      throw new Error(`GET /stream failed: ${streamRes.status} ${text}`)
    }

    console.log(`Sending prompt: ${JSON.stringify(prompt)}`)
    const promptRes = await fetch(`${baseUrl}/prompt`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ message: prompt }),
    })
    if (!promptRes.ok) {
      const text = await promptRes.text()
      throw new Error(`POST /prompt failed: ${promptRes.status} ${text}`)
    }

    const reader = streamRes.body.getReader()
    let buffer = ''
    let repoCloned = false
    let assistantText: string | null = null
    let turnEndSeen = false
    const deadline = Date.now() + timeoutMs

    while (Date.now() < deadline) {
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

        let envelope: unknown
        try {
          envelope = JSON.parse(parsed.data)
        } catch {
          continue
        }
        if (!isRecord(envelope)) continue
        const event = envelope.event
        if (!isRecord(event)) continue

        if (
          event.source === 'daemon' &&
          event.type === 'repo_cloned' &&
          event.repoId === 'repo'
        ) {
          repoCloned = true
        }

        if (event.source !== 'agent') continue
        const payload = event.payload
        if (!isRecord(payload)) continue
        const type = payload.type
        if (type === 'message_end') {
          const extracted = extractAssistantText(payload)
          if (extracted) assistantText = extracted
        }
        if (type === 'turn_end') {
          turnEndSeen = true
          break
        }
      }
      if (turnEndSeen) break
    }

    if (!repoCloned) {
      throw new Error('did not observe repo_cloned event for init repo')
    }
    if (!turnEndSeen) {
      throw new Error('timed out waiting for turn_end event')
    }
    if (!assistantText) {
      throw new Error('did not observe an assistant message')
    }
    if (!looksLikeDirectoryListing(assistantText)) {
      throw new Error(
        `assistant reply did not look like a directory listing: ${
          assistantText.slice(0, 400)
        }`,
      )
    }

    console.log('Shutting down...')
    const shutdownRes = await fetch(`${baseUrl}/shutdown`, { method: 'POST' })
    if (!shutdownRes.ok) {
      const text = await shutdownRes.text()
      throw new Error(`POST /shutdown failed: ${shutdownRes.status} ${text}`)
    }

    // Give the process a moment to exit gracefully; if it doesn't, fall back
    // to killing the container name.
    const graceful = await Promise.race([
      child.status.then(() => true),
      sleep(15_000).then(() => false),
    ])
    if (!graceful) {
      console.error('Container did not exit after /shutdown; forcing stop...')
      const stop = new Deno.Command('docker', {
        args: ['stop', containerName],
        stdin: 'null',
        stdout: 'piped',
        stderr: 'piped',
      })
      await stop.output()
    }

    console.log('Smoke test passed.')
  } finally {
    try {
      const stop = new Deno.Command('docker', {
        args: ['stop', containerName],
        stdin: 'null',
        stdout: 'piped',
        stderr: 'piped',
      })
      await stop.output()
    } catch {
      // ignore
    }
  }
}

if (import.meta.main) {
  try {
    await main()
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    console.error(message)
    try {
      await Deno.stdout.write(encoder.encode(''))
    } catch {
      // ignore
    }
    Deno.exit(1)
  }
}
