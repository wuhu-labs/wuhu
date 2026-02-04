import type {
  SandboxDaemonAbortRequest,
  SandboxDaemonAgentEvent,
  SandboxDaemonPromptRequest,
} from './types.ts'

import type { AgentProvider } from './agent-provider.ts'

/**
 * Deterministic provider used for smoke tests and local development when we
 * don't want to depend on external LLM credentials.
 */
export class MockAgentProvider implements AgentProvider {
  private handlers = new Set<(event: SandboxDaemonAgentEvent) => void>()

  start(): Promise<void> {
    return Promise.resolve()
  }

  stop(): Promise<void> {
    this.handlers.clear()
    return Promise.resolve()
  }

  async sendPrompt(request: SandboxDaemonPromptRequest): Promise<void> {
    const listing =
      'AGENTS.md\ncore\ndeploy\nnotes\nscripts\nweb\nREADME.md\nDockerfile'
    const text = request.message.toLowerCase().includes('pwd')
      ? `pwd contains:\n${listing}`
      : listing

    const events: SandboxDaemonAgentEvent[] = [
      {
        source: 'agent',
        type: 'message_end',
        payload: {
          type: 'message_end',
          message: { role: 'assistant', content: text },
        },
      },
      { source: 'agent', type: 'turn_end', payload: { type: 'turn_end' } },
    ]

    // Emit on a microtask so callers can subscribe to the event stream first.
    queueMicrotask(() => {
      for (const event of events) {
        for (const handler of this.handlers) handler(event)
      }
    })
  }

  abort(_request?: SandboxDaemonAbortRequest): Promise<void> {
    const event: SandboxDaemonAgentEvent = {
      source: 'agent',
      type: 'abort',
      payload: { type: 'abort' },
    }
    for (const handler of this.handlers) handler(event)
    return Promise.resolve()
  }

  onEvent(handler: (event: SandboxDaemonAgentEvent) => void): () => void {
    this.handlers.add(handler)
    return () => this.handlers.delete(handler)
  }
}
