import type {
  SandboxDaemonAbortRequest,
  SandboxDaemonAgentEvent,
  SandboxDaemonPromptRequest,
} from './types.ts'

export interface AgentProvider {
  start(): Promise<void>
  stop(): Promise<void>
  sendPrompt(request: SandboxDaemonPromptRequest): Promise<void>
  abort(request?: SandboxDaemonAbortRequest): Promise<void>
  onEvent(handler: (event: SandboxDaemonAgentEvent) => void): () => void
}

export class FakeAgentProvider implements AgentProvider {
  private handlers = new Set<(event: SandboxDaemonAgentEvent) => void>()

  readonly prompts: SandboxDaemonPromptRequest[] = []
  abortCalls = 0

  async start(): Promise<void> {
    // No-op for fake implementation
  }

  async stop(): Promise<void> {
    this.handlers.clear()
  }

  async sendPrompt(request: SandboxDaemonPromptRequest): Promise<void> {
    this.prompts.push(request)
  }

  async abort(_request?: SandboxDaemonAbortRequest): Promise<void> {
    this.abortCalls++
  }

  onEvent(handler: (event: SandboxDaemonAgentEvent) => void): () => void {
    this.handlers.add(handler)
    return () => {
      this.handlers.delete(handler)
    }
  }

  emit(event: SandboxDaemonAgentEvent): void {
    for (const handler of this.handlers) {
      handler(event)
    }
  }
}
