const encoder = new TextEncoder()
const decoder = new TextDecoder()

const args = new Map<string, string>()
for (let i = 0; i < Deno.args.length; i++) {
  const arg = Deno.args[i]
  if (!arg.startsWith('--')) continue
  const key = arg.slice(2)
  const value = Deno.args[i + 1]
  if (value && !value.startsWith('--')) {
    args.set(key, value)
    i++
  } else {
    args.set(key, 'true')
  }
}

const apiUrl = Deno.env.get('API_URL') ?? 'https://api.wuhu.liu.ms'
const repo = args.get('repo')
if (!repo) {
  console.error('Missing --repo (e.g. --repo paideia-ai/axiia-website)')
  Deno.exit(1)
}
const prompt = args.get('prompt') ?? 'Tell me what this repo is about'
const followup = args.get('followup') ?? 'Give me a quick high-level summary.'
const name = args.get('name')
const timeoutMs = Number(args.get('timeoutMs') ?? 420_000)

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

async function createSandbox() {
  const response = await fetch(`${apiUrl}/sandboxes`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ repo, prompt, name }),
  })
  if (!response.ok) {
    const text = await response.text()
    throw new Error(`create sandbox failed: ${response.status} ${text}`)
  }
  const data = await response.json()
  return data.sandbox as {
    id: string
    namespace: string
    status: string
    podIp?: string | null
    podName?: string | null
    daemonPort?: number
  }
}

async function pollSandbox(id: string) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const response = await fetch(`${apiUrl}/sandboxes/${id}`)
    if (!response.ok) {
      await sleep(2000)
      continue
    }
    const data = await response.json()
    const sandbox = data.sandbox as {
      id: string
      namespace: string
      status: string
      podIp?: string | null
      podName?: string | null
      daemonPort?: number
    }
    if (
      sandbox.status === 'running' &&
      sandbox.podIp &&
      sandbox.daemonPort
    ) {
      return sandbox
    }
    await sleep(2000)
  }
  throw new Error('sandbox did not become ready before timeout')
}

async function runKubectl(args: string[]): Promise<string> {
  const cmd = new Deno.Command('kubectl', {
    args,
    stdout: 'piped',
    stderr: 'piped',
  })
  const output = await cmd.output()
  if (!output.success) {
    const errorText = decoder.decode(output.stderr)
    throw new Error(`kubectl ${args.join(' ')} failed: ${errorText}`)
  }
  return decoder.decode(output.stdout).trim()
}

async function getPodName(id: string, namespace: string) {
  const name = await runKubectl([
    'get',
    'pods',
    '-n',
    namespace,
    '-l',
    `wuhu.sandbox/id=${id}`,
    '-o',
    'jsonpath={.items[0].metadata.name}',
  ])
  if (!name) throw new Error('unable to resolve sandbox pod name')
  return name
}

async function waitForPort(port: number, retries = 30) {
  for (let i = 0; i < retries; i++) {
    try {
      const res = await fetch(
        `http://127.0.0.1:${port}/stream?cursor=0&follow=0`,
      )
      if (res.ok) return
    } catch {
      // ignore
    }
    await sleep(500)
  }
  throw new Error('port-forward did not become ready')
}

function parseSseChunk(chunk: string): { data?: string } {
  const lines = chunk.split(/\r?\n/)
  const dataLines: string[] = []
  for (const line of lines) {
    if (!line || line.startsWith(':')) continue
    if (line.startsWith('data:')) {
      dataLines.push(line.slice('data:'.length).trimStart())
    }
  }
  const data = dataLines.length ? dataLines.join('\n') : undefined
  return { data }
}

function extractAssistantText(payload: any): string | null {
  const message = payload?.message
  if (!message) return null
  const role = typeof message.role === 'string' ? message.role : ''
  if (role !== 'assistant') return null
  const content = message.content
  if (typeof content === 'string') return content.trim()
  if (Array.isArray(content)) {
    let text = ''
    for (const item of content) {
      if (item?.type === 'text' && typeof item.text === 'string') {
        text += item.text
      }
    }
    return text.trim()
  }
  return null
}

async function main() {
  console.log(`Creating sandbox for ${repo}...`)
  const created = await createSandbox()
  console.log(`Sandbox created: ${created.id}`)
  console.log('Waiting for sandbox to be ready...')
  const ready = await pollSandbox(created.id)
  const namespace = ready.namespace
  const podName = ready.podName ??
    (await getPodName(created.id, namespace))
  console.log(`Sandbox ready: ${podName}`)

  const port = 18787
  console.log(`Port-forwarding ${podName} -> localhost:${port}`)
  const pf = new Deno.Command('kubectl', {
    args: ['port-forward', `pod/${podName}`, `${port}:8787`, '-n', namespace],
    stdin: 'null',
    stdout: 'piped',
    stderr: 'piped',
  }).spawn()

  try {
    await waitForPort(port)
    const streamRes = await fetch(
      `http://127.0.0.1:${port}/stream?cursor=0&follow=1`,
      {
        headers: { accept: 'text/event-stream' },
      },
    )
    if (!streamRes.ok || !streamRes.body) {
      const text = await streamRes.text()
      throw new Error(`stream failed: ${streamRes.status} ${text}`)
    }

    const reader = streamRes.body.getReader()
    let buffer = ''
    let assistantReplies = 0
    let followupSent = false
    const deadline = Date.now() + timeoutMs

    console.log('Waiting for initial assistant reply...')

    while (Date.now() < deadline) {
      const { value, done } = await reader.read()
      if (done) break
      buffer += decoder.decode(value, { stream: true })
      const parts = buffer.split(/\r?\n\r?\n/)
      buffer = parts.pop() || ''
      for (const part of parts) {
        if (!part.trim()) continue
        const parsed = parseSseChunk(part)
        if (!parsed.data) continue
        let envelope: any
        try {
          envelope = JSON.parse(parsed.data)
        } catch {
          continue
        }
        const event = envelope?.event
        if (!event || event.source !== 'agent') continue
        const payload = event.payload
        if (payload?.type !== 'message_end') continue
        const text = extractAssistantText(payload)
        if (!text) continue
        assistantReplies++
        console.log(`Assistant reply ${assistantReplies}: ${text.slice(0, 120)}`)
        if (!followupSent && assistantReplies >= 1) {
          console.log('Sending follow-up prompt...')
          const promptRes = await fetch(
            `http://127.0.0.1:${port}/prompt`,
            {
              method: 'POST',
              headers: { 'content-type': 'application/json' },
              body: JSON.stringify({
                message: followup,
                streamingBehavior: 'followUp',
              }),
            },
          )
          if (!promptRes.ok) {
            const text = await promptRes.text()
            throw new Error(`follow-up prompt failed: ${text}`)
          }
          followupSent = true
        }
        if (assistantReplies >= 2) {
          console.log('E2E chat verified (initial + follow-up).')
          return
        }
      }
    }
    throw new Error('timed out waiting for assistant replies')
  } finally {
    try {
      pf.kill('SIGTERM')
    } catch {
      // ignore
    }
  }
}

if (import.meta.main) {
  await main()
}
