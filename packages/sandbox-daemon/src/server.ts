import { Hono } from '@hono/hono/deno'
import { streamSSE } from '@hono/hono/streaming'

import type { AgentProvider } from './agent-provider.ts'
import type {
  SandboxDaemonAbortRequest,
  SandboxDaemonAbortResponse,
  SandboxDaemonCredentialsPayload,
  SandboxDaemonEvent,
  SandboxDaemonInitRequest,
  SandboxDaemonInitResponse,
  SandboxDaemonPromptRequest,
  SandboxDaemonPromptResponse,
  SandboxDaemonStreamEnvelope,
} from './types.ts'

interface EventRecord {
  cursor: number
  event: SandboxDaemonEvent
}

export class InMemoryEventStore {
  #events: EventRecord[] = []
  #nextCursor = 1

  append(event: SandboxDaemonEvent): EventRecord {
    const record: EventRecord = {
      cursor: this.#nextCursor++,
      event,
    }
    this.#events.push(record)
    return record
  }

  getFromCursor(cursor: number): EventRecord[] {
    return this.#events.filter((record) => record.cursor > cursor)
  }
}

export interface SandboxDaemonServerOptions {
  provider: AgentProvider
}

export function createSandboxDaemonApp(options: SandboxDaemonServerOptions) {
  const { provider } = options
  const app = new Hono()
  const eventStore = new InMemoryEventStore()

  provider.onEvent((event) => {
    eventStore.append(event)
  })

  app.post('/credentials', async (c) => {
    const _payload = await c.req.json<SandboxDaemonCredentialsPayload>()
    // Protocol 0: accept and acknowledge. Wiring to actual storage
    // and sandbox environment happens in the concrete daemon.
    return c.json({ ok: true })
  })

  app.post('/init', async (c) => {
    const body = await c.req.json<SandboxDaemonInitRequest>()
    const response: SandboxDaemonInitResponse = {
      ok: true,
      workspace: {
        repos: body.workspace.repos.map((repo) => ({
          id: repo.id,
          path: repo.path,
        })),
      },
    }
    return c.json(response)
  })

  app.post('/prompt', async (c) => {
    const body = await c.req.json<SandboxDaemonPromptRequest>()
    await provider.sendPrompt(body)
    const response: SandboxDaemonPromptResponse = {
      success: true,
      command: 'prompt',
    }
    return c.json(response)
  })

  app.post('/abort', async (c) => {
    const body = (await c.req.json().catch(() => ({}))) as
      | SandboxDaemonAbortRequest
      | undefined
    await provider.abort(body)
    const response: SandboxDaemonAbortResponse = {
      success: true,
      command: 'abort',
    }
    return c.json(response)
  })

  app.get('/stream', (c) => {
    const cursorParam = c.req.query('cursor')
    const cursor = cursorParam ? Number(cursorParam) || 0 : 0

    return streamSSE(c, async (stream) => {
      const records = eventStore.getFromCursor(cursor)
      for (const record of records) {
        const envelope: SandboxDaemonStreamEnvelope<SandboxDaemonEvent> = {
          cursor: record.cursor,
          event: record.event,
        }
        await stream.writeSSE({
          id: String(record.cursor),
          data: JSON.stringify(envelope),
        })
      }
    })
  })

  return { app, eventStore }
}

