import { assertEquals } from '@std/assert'

import { FakeAgentProvider } from '../src/agent-provider.ts'
import { createSandboxDaemonApp } from '../src/server.ts'
import type {
  SandboxDaemonAgentEvent,
  SandboxDaemonPromptRequest,
  SandboxDaemonStreamEnvelope,
} from '../src/types.ts'

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
