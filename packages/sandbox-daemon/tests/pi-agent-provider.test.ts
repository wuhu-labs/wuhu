import { assertEquals } from '@std/assert'

import { PiAgentProvider, type PiTransport } from '../src/pi-agent-provider.ts'
import type { SandboxDaemonAgentEvent } from '../src/types.ts'

class FakePiTransport implements PiTransport {
  readonly lines: string[] = []
  #handlers = new Set<(line: string) => void>()

  async start(): Promise<void> {
    // No-op for fake transport
  }

  async stop(): Promise<void> {
    this.#handlers.clear()
  }

  async send(line: string): Promise<void> {
    this.lines.push(line)
  }

  onLine(handler: (line: string) => void): () => void {
    this.#handlers.add(handler)
    return () => {
      this.#handlers.delete(handler)
    }
  }

  emit(line: string): void {
    for (const handler of this.#handlers) {
      handler(line)
    }
  }
}

Deno.test('PiAgentProvider sendPrompt serializes prompt command', async () => {
  const transport = new FakePiTransport()
  const provider = new PiAgentProvider({ transport })

  await provider.start()

  await provider.sendPrompt({
    message: 'Hello',
    streamingBehavior: 'followUp',
  })

  assertEquals(transport.lines.length, 1)
  const payload = JSON.parse(transport.lines[0]) as {
    type: string
    message: string
    streamingBehavior: string
  }
  assertEquals(payload.type, 'prompt')
  assertEquals(payload.message, 'Hello')
  assertEquals(payload.streamingBehavior, 'followUp')
})

Deno.test('PiAgentProvider emits agent events for non-response lines', async () => {
  const transport = new FakePiTransport()
  const provider = new PiAgentProvider({ transport })

  const events: SandboxDaemonAgentEvent[] = []
  provider.onEvent((event) => {
    events.push(event)
  })

  await provider.start()

  // Non-response event should be forwarded
  transport.emit(JSON.stringify({ type: 'message_update', text: 'hi' }))
  // Response event should be ignored
  transport.emit(JSON.stringify({ type: 'response', command: 'prompt' }))

  assertEquals(events.length, 1)
  const event = events[0]
  assertEquals(event.source, 'agent')
  assertEquals(event.type, 'message_update')
  assertEquals(event.payload.text, 'hi')
})
