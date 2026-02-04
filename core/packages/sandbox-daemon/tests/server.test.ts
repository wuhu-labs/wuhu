import { assertEquals } from '@std/assert'

import { FakeAgentProvider } from '../src/agent-provider.ts'
import { createSandboxDaemonApp } from '../src/server.ts'
import type {
  SandboxDaemonAgentEvent,
  SandboxDaemonCredentialsPayload,
  SandboxDaemonInitRequest,
  SandboxDaemonPromptRequest,
  SandboxDaemonStreamEnvelope,
} from '../src/types.ts'

Deno.test('GET /health returns ok', async () => {
  const provider = new FakeAgentProvider()
  const { app } = createSandboxDaemonApp({ provider })

  const res = await app.request('/health', { method: 'GET' })

  assertEquals(res.status, 200)
  assertEquals(await res.json(), { ok: true })
})

Deno.test('POST /prompt forwards to provider and returns success', async () => {
  const provider = new FakeAgentProvider()
  const { app } = createSandboxDaemonApp({ provider })

  const payload: SandboxDaemonPromptRequest = {
    message: 'Hello, daemon',
  }

  const res = await app.request('/prompt', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
    },
    body: JSON.stringify(payload),
  })

  assertEquals(res.status, 200)
  const json = await res.json()
  assertEquals(json, { success: true, command: 'prompt' })
  assertEquals(provider.prompts.length, 1)
  assertEquals(provider.prompts[0].message, 'Hello, daemon')
})

Deno.test('GET /stream returns SSE with agent events from cursor', async () => {
  const provider = new FakeAgentProvider()
  const { app } = createSandboxDaemonApp({ provider })

  const event: SandboxDaemonAgentEvent = {
    source: 'agent',
    type: 'message_update',
    payload: {
      type: 'message_update',
      text: 'partial',
    },
  }
  provider.emit(event)

  const res = await app.request('/stream?cursor=0', {
    method: 'GET',
  })

  assertEquals(res.status, 200)
  const text = await res.text()

  const dataLines = text.split('\n').filter((line: string) =>
    line.startsWith('data: ')
  )
  assertEquals(dataLines.length, 1)

  const jsonStr = dataLines[0].slice('data: '.length)
  const envelope = JSON.parse(jsonStr) as SandboxDaemonStreamEnvelope<
    SandboxDaemonAgentEvent
  >

  assertEquals(envelope.cursor, 1)
  assertEquals(envelope.event.source, 'agent')
  assertEquals(envelope.event.type, 'message_update')
  assertEquals(envelope.event.payload.text, 'partial')
})

Deno.test('POST /credentials accepts payload and calls hook', async () => {
  const provider = new FakeAgentProvider()
  const received: SandboxDaemonCredentialsPayload[] = []
  const { app } = createSandboxDaemonApp({
    provider,
    onCredentials: (payload) => {
      received.push(payload)
    },
  })

  const payload: SandboxDaemonCredentialsPayload = {
    version: 'test',
    llm: { openaiApiKey: 'sk-test' },
  }

  const res = await app.request('/credentials', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(payload),
  })

  assertEquals(res.status, 200)
  assertEquals(await res.json(), { ok: true })
  assertEquals(received.length, 1)
  assertEquals(received[0].version, 'test')
})

Deno.test('POST /credentials rejects malformed JSON', async () => {
  const provider = new FakeAgentProvider()
  const { app } = createSandboxDaemonApp({ provider })

  const res = await app.request('/credentials', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: '{ "version": "test", ',
  })

  assertEquals(res.status, 400)
  assertEquals(await res.json(), { ok: false, error: 'invalid_json' })
})

Deno.test('POST /init echoes repo summaries', async () => {
  const provider = new FakeAgentProvider()
  const tmp = await Deno.makeTempDir()

  const runGit = async (cwd: string, args: string[]) => {
    const cmd = new Deno.Command('git', {
      args,
      cwd,
      stdin: 'null',
      stdout: 'piped',
      stderr: 'piped',
    })
    const out = await cmd.output()
    if (!out.success) {
      throw new Error(new TextDecoder().decode(out.stderr))
    }
    return new TextDecoder().decode(out.stdout)
  }

  const sourceRepo = `${tmp}/source`
  const workspaceRoot = `${tmp}/ws`
  await Deno.mkdir(sourceRepo, { recursive: true })
  await runGit(sourceRepo, ['init', '-b', 'main'])
  await runGit(sourceRepo, ['config', 'user.email', 'test@example.com'])
  await runGit(sourceRepo, ['config', 'user.name', 'Test'])
  await Deno.writeTextFile(`${sourceRepo}/README.md`, 'hello')
  await runGit(sourceRepo, ['add', '.'])
  await runGit(sourceRepo, ['commit', '-m', 'init'])

  const { app } = createSandboxDaemonApp({ provider, workspaceRoot })

  const payload: SandboxDaemonInitRequest = {
    workspace: {
      repos: [
        { id: 'repo-a', source: sourceRepo, path: 'repo-a' },
      ],
    },
  }

  const res = await app.request('/init', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(payload),
  })

  assertEquals(res.status, 200)
  const json = await res.json()
  assertEquals(json.ok, true)
  assertEquals(json.workspace.repos.length, 1)
  assertEquals(json.workspace.repos[0].id, 'repo-a')
  assertEquals(json.workspace.repos[0].path, 'repo-a')
  assertEquals(json.workspace.repos[0].currentBranch, 'main')
})

Deno.test('POST /shutdown triggers shutdown hook', async () => {
  const provider = new FakeAgentProvider()
  let called = false
  const { app } = createSandboxDaemonApp({
    provider,
    onShutdown: () => {
      called = true
    },
  })

  const res = await app.request('/shutdown', { method: 'POST' })

  assertEquals(res.status, 200)
  assertEquals(await res.json(), { ok: true })
  assertEquals(called, true)
})
